package org.mewx.wenku8_flutter

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import java.io.File
import java.util.UUID

internal class BookFolderScanner(private val activity: Activity) {
    private val preferences = activity.getSharedPreferences("book_folder_scanner", 0)
    private data class Candidate(
        val token: String,
        val name: String,
        val uri: Uri,
        val grantUri: Uri,
        val size: Long,
        val modified: Long,
        val folder: String,
        val fingerprint: String,
    )
    private val session = linkedMapOf<String, Candidate>()

    fun canReadAll(): Boolean = if (Build.VERSION.SDK_INT >= 30) {
        Environment.isExternalStorageManager()
    } else {
        activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }

    fun selectAll(): Map<String, Any> {
        check(
            preferences.edit()
                .putBoolean("all_storage", true)
                .remove("tree_uri")
                .putString("folder_name", "本机共享存储")
                .commit(),
        )
        return info()!!
    }

    fun select(uri: Uri, flags: Int): Map<String, Any> {
        val readFlags = flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (readFlags != 0) {
            try {
                activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: SecurityException) {
            }
        }
        val folderName = resolveTreeName(uri)
        check(
            preferences.edit()
                .putBoolean("all_storage", false)
                .putString("tree_uri", uri.toString())
                .putString("folder_name", folderName)
                .commit(),
        )
        return info()!!
    }

    fun info(): Map<String, Any>? {
        val allStorage = preferences.getBoolean("all_storage", false)
        val treeUri = preferences.getString("tree_uri", null)
        if (!allStorage && treeUri.isNullOrBlank()) return null
        val automatic = preferences.getBoolean("automatic", false)
        val name = preferences.getString("folder_name", null)
            ?.takeIf { it.isNotBlank() }
            ?: if (allStorage) "本机共享存储" else "已选文件夹"
        val readable = if (allStorage) canReadAll() else treeUri != null && canReadTree(Uri.parse(treeUri))
        return mapOf(
            "name" to name,
            "automatic" to automatic,
            "readable" to readable,
            "all" to allStorage,
        )
    }

    fun setAutomatic(value: Boolean) {
        check(preferences.edit().putBoolean("automatic", value).commit())
    }

    fun disconnect() {
        preferences.getString("tree_uri", null)?.let { raw ->
            try {
                activity.contentResolver.releasePersistableUriPermission(
                    Uri.parse(raw),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (_: Exception) {
            }
        }
        session.clear()
        check(
            preferences.edit()
                .remove("all_storage")
                .remove("tree_uri")
                .remove("folder_name")
                .remove("automatic")
                .commit(),
        )
    }

    fun formats(): Set<String> {
        val stored = preferences.getStringSet("extensions", null)
        return if (stored.isNullOrEmpty()) {
            setOf("txt", "epub", "mobi", "azw", "azw3", "prc", "pdf", "fb2", "docx", "doc", "rtf", "html", "htm", "xhtml", "md", "markdown", "zip")
        } else {
            stored.map { it.lowercase() }.toSet()
        }
    }

    fun setFormats(extensions: List<String>) {
        val cleaned = extensions.map { it.trim().trimStart('.').lowercase() }.filter { it.isNotEmpty() }.toSet()
        check(preferences.edit().putStringSet("extensions", cleaned).commit())
    }

    fun scan(): Map<String, Any> {
        session.clear()
        val allowed = formats()
        val seen = preferences.getStringSet("imported_fingerprints", emptySet()).orEmpty()
        val books = mutableListOf<Map<String, Any?>>()
        val warnings = mutableListOf<String>()
        var total = 0
        var unchanged = 0

        val allStorage = preferences.getBoolean("all_storage", false)
        val treeRaw = preferences.getString("tree_uri", null)
        if (allStorage) {
            if (!canReadAll()) {
                warnings += "尚未授予本机共享存储读取权限"
            } else {
                val rootDir = Environment.getExternalStorageDirectory()
                scanDirectory(rootDir, "", allowed, seen, books, warnings) { totalCount, unchangedCount ->
                    total += totalCount
                    unchanged += unchangedCount
                }
            }
        } else if (!treeRaw.isNullOrBlank()) {
            val treeUri = Uri.parse(treeRaw)
            val docId = DocumentsContract.getTreeDocumentId(treeUri)
            scanDocumentTree(treeUri, docId, "", allowed, seen, books, warnings) { totalCount, unchangedCount ->
                total += totalCount
                unchanged += unchangedCount
            }
        }
        return mapOf(
            "books" to books,
            "total" to total,
            "unchanged" to unchanged,
            "warnings" to warnings,
        )
    }

    fun stage(token: String, importRoot: File, copy: (Uri, File, Long) -> Unit): Map<String, String> {
        val candidate = session[token] ?: error("扫描条目已过期，请重新扫描")
        val target = File.createTempFile("import-", ".source", importRoot)
        try {
            copy(candidate.uri, target, BookArchiveImport.limit(candidate.name))
            return mapOf("name" to candidate.name, "path" to target.path)
        } catch (error: Exception) {
            target.delete()
            throw error
        }
    }

    fun link(token: String, links: BookTextLinks, importRoot: File, copy: (Uri, File, Long) -> Unit): Map<String, String> {
        val candidate = session[token] ?: error("扫描条目已过期，请重新扫描")
        return try {
            val ref = links.remember(candidate.uri, candidate.grantUri)
            mapOf("name" to candidate.name, "reference" to ref)
        } catch (_: Exception) {
            stage(token, importRoot, copy)
        }
    }

    fun markImported(token: String) {
        val candidate = session[token] ?: return
        val updated = preferences.getStringSet("imported_fingerprints", emptySet()).orEmpty().toMutableSet()
        updated += candidate.fingerprint
        preferences.edit().putStringSet("imported_fingerprints", updated).apply()
    }

    fun finish() {
        session.clear()
    }

    private fun resolveTreeName(treeUri: Uri): String {
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
            activity.contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            } ?: "已选文件夹"
        } catch (_: Exception) {
            "已选文件夹"
        }
    }

    private fun canReadTree(treeUri: Uri): Boolean {
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
            activity.contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { it.count >= 0 } ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun scanDirectory(
        dir: File,
        relativeFolder: String,
        allowed: Set<String>,
        seen: Set<String>,
        books: MutableList<Map<String, Any?>>,
        warnings: MutableList<String>,
        depth: Int = 0,
        onCount: (Int, Int) -> Unit,
    ) {
        if (depth > 24 || books.size >= 5000) return
        val children = dir.listFiles() ?: return
        for (child in children) {
            if (books.size >= 5000) break
            if (child.name.startsWith(".")) continue
            if (child.isDirectory) {
                if (child.name.equals("Android", ignoreCase = true) && relativeFolder.isEmpty()) continue
                val nextFolder = if (relativeFolder.isEmpty()) child.name else "$relativeFolder/${child.name}"
                scanDirectory(child, nextFolder, allowed, seen, books, warnings, depth + 1, onCount)
            } else if (child.isFile) {
                val ext = child.name.substringAfterLast('.', "").lowercase()
                if (ext !in allowed || !BookArchiveImport.supported(child.name)) continue
                val fingerprint = "${child.absolutePath}:${child.length()}:${child.lastModified()}"
                if (fingerprint in seen) {
                    onCount(1, 1)
                    continue
                }
                onCount(1, 0)
                val token = UUID.randomUUID().toString()
                val uri = Uri.fromFile(child)
                session[token] = Candidate(
                    token = token,
                    name = child.name,
                    uri = uri,
                    grantUri = uri,
                    size = child.length(),
                    modified = child.lastModified(),
                    folder = relativeFolder,
                    fingerprint = fingerprint,
                )
                books += mapOf(
                    "token" to token,
                    "name" to child.name,
                    "size" to child.length(),
                    "folder" to relativeFolder,
                )
            }
        }
    }

    private fun scanDocumentTree(
        treeUri: Uri,
        parentDocId: String,
        relativeFolder: String,
        allowed: Set<String>,
        seen: Set<String>,
        books: MutableList<Map<String, Any?>>,
        warnings: MutableList<String>,
        depth: Int = 0,
        onCount: (Int, Int) -> Unit,
    ) {
        if (depth > 24 || books.size >= 5000) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        try {
            activity.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (books.size >= 5000) break
                    val docId = cursor.getString(0) ?: continue
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2) ?: ""
                    val size = if (cursor.isNull(3)) 0L else cursor.getLong(3)
                    val modified = if (cursor.isNull(4)) 0L else cursor.getLong(4)
                    if (name.startsWith(".")) continue
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        val nextFolder = if (relativeFolder.isEmpty()) name else "$relativeFolder/$name"
                        scanDocumentTree(treeUri, docId, nextFolder, allowed, seen, books, warnings, depth + 1, onCount)
                    } else {
                        val ext = name.substringAfterLast('.', "").lowercase()
                        if (ext !in allowed || !BookArchiveImport.supported(name)) continue
                        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                        val fingerprint = "$docUri:$size:$modified"
                        if (fingerprint in seen) {
                            onCount(1, 1)
                            continue
                        }
                        onCount(1, 0)
                        val token = UUID.randomUUID().toString()
                        session[token] = Candidate(
                            token = token,
                            name = name,
                            uri = docUri,
                            grantUri = treeUri,
                            size = size,
                            modified = modified,
                            folder = relativeFolder,
                            fingerprint = fingerprint,
                        )
                        books += mapOf(
                            "token" to token,
                            "name" to name,
                            "size" to size,
                            "folder" to relativeFolder,
                        )
                    }
                }
            }
        } catch (error: Exception) {
            warnings += (error.message ?: "部分子文件夹无法读取")
        }
    }
}
