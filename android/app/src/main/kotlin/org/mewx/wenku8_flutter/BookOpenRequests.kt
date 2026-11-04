package org.mewx.wenku8_flutter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Build
import android.os.Process
import android.content.pm.PackageManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File
import java.util.UUID

/** Engine-owned inbox. UI recreation must not lose a pending ACTION_VIEW or
 * replay it. No incoming URI/path is exposed to Dart or diagnostic messages. */
internal class BookOpenRequests(private val context: Context) {
    private data class Request(val id: String, val uri: Uri, val flags: Int, val mime: String?) {
        var newGrant = false
        var linked: Link? = null
    }
    private data class Link(val uri: Uri, val grant: Uri? = null)
    private val requests = linkedMapOf<String, Request>()

    @Synchronized fun offer(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_VIEW) return false
        val uri = intent.data ?: return false
        if (uri.scheme !in setOf("content", "file")) return false
        if (requests.values.none { it.uri == uri }) {
            val id = UUID.randomUUID().toString()
            requests[id] = Request(id, uri, intent.flags, intent.type)
        }
        return true
    }

    @Synchronized private fun request(id: String): Request = requests[id]
        ?: error("文件打开请求已结束，请从文件管理器重新打开")

    private fun valid(uri: Uri) {
        require(uri.scheme in setOf("content", "file")) { "请从文件管理器打开本地书籍" }
        if (uri.scheme == "file") {
            val file = File(uri.path ?: "").canonicalFile
            val shared = Environment.getExternalStorageDirectory().canonicalFile
            require(file.path.startsWith(shared.path + File.separator)) { "请通过系统文件选择器授权这本书" }
        } else {
            require(!uri.authority.isNullOrBlank() && uri.authority != "${context.packageName}.updates") {
                "这个文件位置不支持阅读，请重新选择书籍"
            }
        }
    }

    private fun name(request: Request): String {
        valid(request.uri)
        val display = if (request.uri.scheme == "content") context.contentResolver.query(request.uri,
            arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
        } else null
        return BookOpenNames.resolve(display ?: request.uri.lastPathSegment.orEmpty(), request.mime)
    }

    private fun hasGrant(uri: Uri) = context.contentResolver.persistedUriPermissions.any {
        it.isReadPermission && it.uri == uri
    }

    private fun pickerUri(request: Request): Uri? {
        if (Build.VERSION.SDK_INT < 26) return null
        if (DocumentsContract.isDocumentUri(context, request.uri)) return request.uri
        if (request.uri.authority != MediaStore.AUTHORITY) return null
        return runCatching { MediaStore.getDocumentUri(context, request.uri) }
            .getOrNull()?.takeIf { DocumentsContract.isDocumentUri(context, it) }
    }

    private fun sourceName(uri: Uri): String? {
        val authority = uri.authority ?: return null
        return runCatching {
            context.packageManager.resolveContentProvider(authority, 0)
                ?.loadLabel(context.packageManager)?.toString()?.trim()
                ?.takeIf { it.isNotEmpty() && it.length <= 256 && it.none { c -> c.code < 32 } }
        }.getOrNull()
    }

    private fun sourceLocation(uri: Uri): String? {
        if (Build.VERSION.SDK_INT < 26 || !DocumentsContract.isTreeUri(uri)) return null
        return runCatching {
            val path = DocumentsContract.findDocumentPath(context.contentResolver, uri)?.path ?: return null
            val names = path.dropLast(1).take(32).map { id ->
                val document = DocumentsContract.buildDocumentUriUsingTree(uri, id)
                context.contentResolver.query(document, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst() && !it.isNull(0)) it.getString(0) else null
                } ?: return null
            }
            names.joinToString(" / ").takeIf { it.isNotBlank() && it.length <= 1024 }
        }.getOrNull()
    }

    private fun canMove(request: Request, display: String): Boolean {
        val document = DocumentsContract.isDocumentUri(context, request.uri)
        val writable = context.checkUriPermission(request.uri, Process.myPid(), Process.myUid(),
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED
        if (!bookOpenMoveAllowed(display, document, writable, true)) return false
        val deletable = runCatching {
            context.contentResolver.query(request.uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
                it.moveToFirst() && !it.isNull(0) &&
                    (it.getInt(0) and DocumentsContract.Document.FLAG_SUPPORTS_DELETE) != 0
            } == true
        }.getOrDefault(false)
        return bookOpenMoveAllowed(display, document, writable, deletable)
    }

    private fun link(request: Request): Link? {
        request.linked?.let { return it }
        if (request.uri.scheme == "file") {
            check(File(request.uri.path!!).canRead()) { "无法读取这本书，请重新定位原文件" }
            return Link(request.uri).also { request.linked = it }
        }
        val persisted = retainBookOpenReadGrant(
            request.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0,
            { hasGrant(request.uri) },
            {
                context.contentResolver.takePersistableUriPermission(request.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                request.newGrant = true
            },
        )
        if (persisted) return Link(request.uri, request.uri).also { request.linked = it }
        // Some file managers grant VIEW access but not a persistable URI. If
        // this app already has shared-file access, retain that original path;
        // never ask for broader access or copy the book as a side effect.
        context.contentResolver.openAssetFileDescriptor(request.uri, "r")?.use { descriptor ->
            if (descriptor.startOffset == 0L) {
                val local = runCatching {
                    val target = File(android.system.Os.readlink("/proc/self/fd/${descriptor.parcelFileDescriptor.fd}")).canonicalFile
                    val shared = Environment.getExternalStorageDirectory().canonicalFile
                    if (!target.path.startsWith(shared.path + File.separator) || !target.canRead()) null
                    else target.inputStream().use { input ->
                        val source = android.system.Os.fstat(descriptor.fileDescriptor)
                        val reopened = android.system.Os.fstat(input.fd)
                        target.takeIf { source.st_dev == reopened.st_dev && source.st_ino == reopened.st_ino }
                    }
                }.getOrNull()
                if (local != null) return Link(Uri.fromFile(local)).also { request.linked = it }
            }
        } ?: error("文件应用未授予读取权限，请重新打开原文件")
        // A readable VIEW grant is not a durable library reference. QQ and
        // other providers can revoke it when this activity/task ends. Let the
        // shared UI obtain a lasting picker grant or an explicit managed copy.
        return null
    }

    fun pending(): Map<String, Any>? {
        val request = synchronized(this) { requests.values.firstOrNull() } ?: return null
        return try {
            val display = name(request)
            val durable = link(request) != null
            mutableMapOf<String, Any>("id" to request.id, "name" to display, "canLink" to durable,
                "canLocate" to (pickerUri(request) != null), "canMove" to canMove(request, display)).apply {
                sourceName(request.uri)?.let { put("sourceName", it) }
                sourceLocation(request.uri)?.let { put("sourceLocation", it) }
            }
        } catch (error: Exception) {
            mapOf("id" to request.id, "name" to "所选书籍", "canLink" to false, "error" to bookImportMessage(error))
        }
    }

    fun initialUri(id: String): Uri = request(id).let { pickerUri(it) ?: it.uri }

    fun deleteSource(id: String, path: String) {
        val request = try {
            val offered = request(id)
            check(canMove(offered, name(offered))) { "来源未授予删除权限，原文件未删除" }
            val copy = File(path).canonicalFile
            val app = File(context.applicationInfo.dataDir).canonicalFile
            check(copy.path.startsWith(app.path + File.separator) && copy.name == "original" &&
                File(copy.parentFile, "book.json").isFile) { "书库副本尚未确认，原文件未删除" }
            context.contentResolver.openInputStream(offered.uri)?.use { source ->
                copy.inputStream().use { saved ->
                    check(sameBookOpenBytes(source, saved)) { "原文件已变化或副本不完整，原文件未删除" }
                }
            } ?: error("无法核对原文件，原文件未删除")
            offered
        } catch (error: Exception) {
            throw BookOpenMoveFailure("move_not_deleted", error.message ?: "未通过核对，原文件未删除")
        }
        val deleted = try { DocumentsContract.deleteDocument(context.contentResolver, request.uri) }
        catch (_: Exception) {
            throw BookOpenMoveFailure("move_unconfirmed", "已导入书库，但未能确认原文件是否删除")
        }
        if (!deleted) throw BookOpenMoveFailure("move_not_deleted", "来源未完成删除，原文件未删除")
    }

    fun resolve(id: String, copy: Boolean, links: BookTextLinks,
        imports: BookDocumentImportSession<Uri>): Map<String, String> {
        val request = request(id)
        val display = name(request)
        return if (copy) imports.queue.select(request.uri, display, BookArchiveImport.limit(display))
        else {
            val source = link(request)
                ?: error("文件应用只提供了临时读取权限，请重新选择原文件，或选择「复制到应用」")
            mapOf("name" to display, "reference" to links.remember(source.uri, source.grant))
        }
    }

    fun finish(id: String, links: BookTextLinks) {
        val request = synchronized(this) { requests.remove(id) } ?: return
        if (request.newGrant && !links.usesGrant(request.uri)) {
            try { context.contentResolver.releasePersistableUriPermission(request.uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            catch (_: SecurityException) { /* Revoked already. */ }
        }
    }
}

internal object BookOpenNames {
    private val extensions = mapOf(
        "text/plain" to "txt", "application/epub+zip" to "epub",
        "application/x-mobipocket-ebook" to "mobi", "application/vnd.amazon.ebook" to "azw",
        "application/vnd.amazon.mobi8-ebook" to "azw3",
        "application/x-fictionbook+xml" to "fb2", "application/fb2+xml" to "fb2",
        "application/pdf" to "pdf", "application/rtf" to "rtf", "text/rtf" to "rtf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" to "docx",
        "application/msword" to "doc",
        "text/html" to "html", "application/xhtml+xml" to "xhtml",
        "text/markdown" to "md", "text/x-markdown" to "md",
        "application/zip" to "zip", "application/x-zip-compressed" to "zip",
    )
    fun resolve(raw: String, mime: String?): String {
        var name = raw.replace('\\', '/').substringAfterLast('/').trim()
        require(name.length <= 1024 && name.none { it.code < 32 || it.code == 127 }) { "书籍文件名有误，请重新选择" }
        if ('.' !in name || !BookArchiveImport.supported(name)) {
            val extension = extensions[mime?.substringBefore(';')?.trim()?.lowercase()]
            require(extension != null && (name.isBlank() || '.' !in name)) { "请选择支持的电子书或文档" }
            name = "${name.ifBlank { "所选书籍" }}.$extension"
        }
        return name
    }
}
