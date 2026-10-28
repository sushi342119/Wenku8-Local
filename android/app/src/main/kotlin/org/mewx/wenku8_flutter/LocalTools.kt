package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import local.saf.localDeleteOutcome
import local.saf.localRenameOutcome
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.nio.charset.CharacterCodingException
import android.content.Context
import org.json.JSONArray
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/** Explicit document/folder/share actions; never touches the Wenku8 bridge/session. */
class LocalTools(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val io = Executors.newSingleThreadExecutor()
    private val requests = LocalToolRequests { callback -> activity.runOnUiThread { callback() } }
    private data class Pending(val result: MethodChannel.Result, val export: String?, val legacy: Boolean = false)
    private var pending: Pending? = null
    private var pendingFolder: MethodChannel.Result? = null
    private var pendingFont: MethodChannel.Result? = null
    private val closed get() = requests.closed
    companion object {
        private const val REQUEST = 8019
        private const val REQUEST_FOLDER = 8021
        private const val REQUEST_FONT = 8023
        private const val MAX_FONT_BYTES = 100 * 1024 * 1024
        private const val MAX_BYTES = 4 * 1024 * 1024
        private const val MAX_TEXT_BYTES = 256 * 1024 * 1024
        private const val MAX_TEXT_BUFFER_BYTES = 4 * 1024 * 1024
        private const val MAX_SCAN_FILES = 30000
        private const val IO_TIMEOUT_MS = 20000L
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (handleLibrary(call, result)) return
        when (call.method) {
            "getKeepScreenOn" -> result.success(
                activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
            )
            "keepScreenOn" -> {
                if (call.arguments == true) {
                    activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "shareText" -> {
                val text = call.argument<String>("text") ?: ""
                if (text.isBlank() || text.length > 10000) {
                    result.error("input", "Invalid share text", null)
                } else try {
                    activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                    }, "分享图书"))
                    result.success(null)
                } catch (_: Exception) { result.error("share", "Share sheet did not open", null) }
            }
            "exportBackup", "importBackup", "importLegacyData" -> {
                if (pending != null || closed) {
                    result.error("busy", "A document operation is already active", null)
                    return
                }
                val text = if (call.method == "exportBackup") call.argument<String>("text") else null
                val legacy = call.method == "importLegacyData"
                if (call.method == "exportBackup" && (text == null || text.toByteArray(Charsets.UTF_8).size > MAX_BYTES)) {
                    result.error("size", "Backup exceeds the document limit", null)
                    return
                }
                val intent = Intent(if (legacy) Intent.ACTION_OPEN_DOCUMENT_TREE else if (text == null) Intent.ACTION_OPEN_DOCUMENT else Intent.ACTION_CREATE_DOCUMENT).apply {
                    if (!legacy) {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (text == null) "*/*" else "application/json"
                        if (text == null) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/plain", "application/octet-stream"))
                        else putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "wenku8-backup.json")
                    }
                }
                if (!requests.begin(result)) return
                pending = Pending(result, text, legacy)
                try {
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(intent, REQUEST)
                } catch (_: Exception) {
                    pending = null
                    requests.error(result, "picker", "Document picker could not open")
                }
            }
            else -> result.notImplemented()
        }
    }

    /** 本地书库：SAF 文件夹选择 / 扫描 / 文本读取 / PDF 渲染。与上方文档操作互相独立。 */
    private fun handleLibrary(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf(
                "pickLocalFolder", "queryTreePermission", "scanLocalFolder", "readLocalText", "fingerprintLocalText", "prepareLocalText", "writeLibraryPreferences", "decodeLocalText", "pdfPageCount", "renderPdfPage",
                "clearPdfCache", "deleteLocalDocument", "renameLocalDocument", "pickFontFile"
            )
        ) return false
        if (closed) {
            result.error("closed", "Activity closed", null)
            return true
        }
        when (call.method) {
            "pickLocalFolder" -> {
                if (pendingFolder != null) {
                    result.error("busy", "A folder picker is already active", null)
                    return true
                }
                if (!requests.begin(result)) return true
                pendingFolder = result
                try {
                    // 显式申请读写 + 可持久化：删除/重命名源文件需要写权限，
                    // 只授读权限时这些操作会被 provider 拒绝。
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                    }
                    activity.startActivityForResult(intent, REQUEST_FOLDER)
                } catch (_: Exception) {
                    pendingFolder = null
                    requests.error(result, "picker", "Folder picker could not open")
                }
                return true
            }
            "pickFontFile" -> {
                if (pendingFont != null) {
                    result.error("busy", "A font picker is already active", null)
                    return true
                }
                if (!requests.begin(result)) return true
                pendingFont = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "font/ttf", "font/otf", "font/ttc",
                                "application/font-sfnt",
                                "application/x-font-ttf", "application/x-font-otf",
                            ),
                        )
                    }
                    activity.startActivityForResult(intent, REQUEST_FONT)
                } catch (_: Exception) {
                    pendingFont = null
                    requests.error(result, "picker", "Font picker could not open")
                }
                return true
            }
            "scanLocalFolder", "readLocalText", "fingerprintLocalText", "prepareLocalText", "writeLibraryPreferences", "decodeLocalText", "pdfPageCount", "renderPdfPage", "clearPdfCache",
            "deleteLocalDocument", "renameLocalDocument", "queryTreePermission" -> {
                val timeout = when (call.method) {
                    "prepareLocalText", "fingerprintLocalText" -> 120000L
                    "scanLocalFolder", "queryTreePermission", "readLocalText",
                    "pdfPageCount", "writeLibraryPreferences" -> IO_TIMEOUT_MS
                    else -> null
                }
                if (!requests.begin(result, timeout)) return true
                val work = io.submit {
                    if (!requests.active(result)) return@submit
                    try {
                        val response: Any = when (call.method) {
                            "scanLocalFolder" -> scanLocalFolder(Uri.parse(call.argument<String>("treeUri") ?: ""))
                            "queryTreePermission" -> queryTreePermission(Uri.parse(call.argument<String>("treeUri") ?: ""))
                            "readLocalText" -> readLocalText(Uri.parse(call.argument<String>("docUri") ?: ""))
                            "fingerprintLocalText" -> fingerprintLocalText(Uri.parse(call.argument<String>("docUri") ?: ""))
                            "prepareLocalText" -> prepareLocalText(
                                Uri.parse(call.argument<String>("docUri") ?: ""),
                                call.argument<Boolean>("withFingerprint") == true,
                            )
                            "writeLibraryPreferences" -> writeLibraryPreferences(call.argument<Map<String, Any?>>("changes") ?: emptyMap())
                            "deleteLocalDocument" -> deleteLocalDocument(Uri.parse(call.argument<String>("docUri") ?: ""))
                            "renameLocalDocument" -> renameLocalDocument(
                                Uri.parse(call.argument<String>("docUri") ?: ""),
                                call.argument<String>("newFileName") ?: "",
                                call.argument<String>("expectedFileName"),
                            )
                            "decodeLocalText" -> decodeLocalText(
                                call.argument<ByteArray>("bytes"),
                                call.argument<String>("encoding") ?: "auto"
                            )
                            "pdfPageCount" -> pdfPageCount(Uri.parse(call.argument<String>("docUri") ?: ""))
                            "clearPdfCache" -> clearPdfCache(Uri.parse(call.argument<String>("docUri") ?: ""))
                            else -> renderPdfPage(
                                Uri.parse(call.argument<String>("docUri") ?: ""),
                                call.argument<Int>("page") ?: 0,
                                call.argument<Int>("widthPx") ?: 1200,
                            )
                        }
                        activity.runOnUiThread {
                            if (!requests.complete(result) { result.success(response) } && call.method == "prepareLocalText") {
                                val path = if (response is String) response else (response as? Map<*, *>)?.get("path") as? String
                                if (path != null) File(path).delete()
                            }
                        }
                    } catch (e: SecurityException) {
                        requests.error(result, "permission", "Folder permission was revoked")
                    } catch (e: Exception) {
                        requests.error(result, "local", e.message ?: "Local file operation failed")
                    }
                }
                requests.track(result, work)
                return true
            }
        }
        return false
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request == REQUEST_FONT) {
            val result = pendingFont
            pendingFont = null
            if (result == null) return true
            val uri = data?.data
            if (code != Activity.RESULT_OK || uri == null) {
                requests.success(result, null)
                return true
            }
            val work = io.submit {
                if (!requests.active(result)) return@submit
                try {
                    val path = copyFontToPrivateDir(uri)
                    requests.success(result, path)
                } catch (e: SecurityException) {
                    requests.error(result, "permission", "Font permission was revoked")
                } catch (e: Exception) {
                    requests.error(result, "font", e.message ?: "Font import failed")
                }
            }
            requests.track(result, work)
            return true
        }
        if (request == REQUEST_FOLDER) {
            val result = pendingFolder
            pendingFolder = null
            if (result == null) return true
            val uri = data?.data
            if (code != Activity.RESULT_OK || uri == null) {
                requests.success(result, null)
                return true
            }
            try {
                // 只持久化系统实际授予的权限（用返回 Intent 的 flags 做掩码）：
                // 强传未授予的 WRITE 会抛 SecurityException；旧版固定只取 READ，
                // 导致写授权未持久化，重启后删除/重命名源文件全部被拒。
                val granted = (data?.flags ?: 0) and (
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                val takeFlags = if (granted != 0) granted
                else Intent.FLAG_GRANT_READ_URI_PERMISSION
                activity.contentResolver.takePersistableUriPermission(uri, takeFlags)
                requests.success(result, uri.toString())
            } catch (_: Exception) {
                requests.error(result, "permission", "Folder permission was not granted")
            }
            return true
        }
        if (request != REQUEST) return false
        val operation = pending ?: return true
        val uri = data?.data
        if (code != Activity.RESULT_OK || uri == null) {
            pending = null
            requests.success(operation.result, if (operation.export == null) null else false)
            return true
        }
        val work = io.submit {
            if (!requests.active(operation.result)) return@submit
            try {
                val response: Any = if (operation.legacy) {
                    readLegacyTree(uri)
                } else if (operation.export != null) {
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        output.write(operation.export.toByteArray(Charsets.UTF_8))
                        output.flush()
                    } ?: throw IllegalStateException("Document is not writable")
                    true
                } else {
                    val bytes = ByteArrayOutputStream()
                    activity.contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (bytes.size() + count > MAX_BYTES) throw IllegalArgumentException("Document is too large")
                            bytes.write(buffer, 0, count)
                        }
                    } ?: throw IllegalStateException("Document is not readable")
                    Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
                }
                activity.runOnUiThread {
                    requests.complete(operation.result) {
                        pending = null
                        operation.result.success(response)
                    }
                }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    requests.complete(operation.result) {
                        pending = null
                        operation.result.error("document", "Document read or write failed", null)
                    }
                }
            }
        }
        requests.track(operation.result, work)
        return true
    }

    /** 递归扫描 SAF 树中的 txt / pdf，仅返回名称、大小与修改时间，不读内容。 */
    private fun scanLocalFolder(tree: Uri): Map<String, Any?> {
        data class Doc(val id: String, val name: String, val dir: Boolean, val size: Long, val modified: Long)
        fun children(id: String): List<Doc> {
            val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            val columns = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            return activity.contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
                val records = ArrayList<Doc>()
                while (cursor.moveToNext()) {
                    if (Thread.currentThread().isInterrupted) throw InterruptedException()
                    if (records.size >= MAX_SCAN_FILES) break
                    val size = try { cursor.getLong(3) } catch (_: Exception) { 0L }
                    val modified = try { cursor.getLong(4) } catch (_: Exception) { 0L }
                    records.add(
                        Doc(cursor.getString(0), cursor.getString(1) ?: "",
                            cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, size, modified)
                    )
                }
                records
            } ?: throw IllegalStateException("Folder is not readable")
        }
        val output = ArrayList<Map<String, Any>>()
        var complete = true
        var reason: String? = null
        fun walk(id: String, depth: Int) {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            if (!complete) return
            if (depth > 10) {
                complete = false
                reason = "depth_limit"
                return
            }
            if (output.size >= MAX_SCAN_FILES) {
                complete = false
                reason = "limit"
                return
            }
            val docs: List<Doc>
            try {
                docs = children(id)
            } catch (e: SecurityException) {
                complete = false
                reason = "permission"
                return
            } catch (e: Exception) {
                complete = false
                reason = "enumeration_failed"
                return
            }
            for (doc in docs) {
                if (!complete) break
                if (doc.dir) {
                    walk(doc.id, depth + 1)
                } else {
                    val lower = doc.name.lowercase()
                    if (lower.endsWith(".txt") || lower.endsWith(".pdf")) {
                        output.add(
                            mapOf(
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, doc.id).toString(),
                                "name" to doc.name,
                                "size" to doc.size,
                                "modified" to doc.modified,
                            )
                        )
                        if (output.size >= MAX_SCAN_FILES) {
                            complete = false
                            reason = "limit"
                            return
                        }
                    }
                }
            }
        }
        try {
            walk(DocumentsContract.getTreeDocumentId(tree), 0)
        } catch (e: SecurityException) {
            complete = false
            reason = "permission"
        } catch (e: Exception) {
            complete = false
            reason = "enumeration_failed"
        }
        return mapOf(
            "entries" to output,
            "complete" to complete,
            "reason" to reason,
        )
    }

    /** One Editor commit for all library keys; the Dart rollback journal brackets it. */
    private fun writeLibraryPreferences(changes: Map<String, Any?>): Boolean {
        val editor = activity.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE).edit()
        for ((key, value) in changes) {
            val prefixed = "flutter.$key"
            when (value) {
                null -> editor.remove(prefixed)
                is Boolean -> editor.putBoolean(prefixed, value)
                is Int -> editor.putLong(prefixed, value.toLong())
                is Long -> editor.putLong(prefixed, value)
                is Double -> editor.putString(prefixed, "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu$value")
                is String -> {
                    require(!value.startsWith("VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu") &&
                        !value.startsWith("VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy") &&
                        !value.startsWith("VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu")) {
                        "StorageError: String clashes with special identifier prefixes"
                    }
                    editor.putString(prefixed, value)
                }
                is List<*> -> {
                    require(value.all { it is String })
                    // The legacy shared_preferences plugin's JSON string-list encoding.
                    editor.putString(prefixed, "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!" + JSONArray(value).toString())
                }
                else -> throw IllegalArgumentException("Unsupported preference value")
            }
        }
        return editor.commit()
    }

    /** Hash source bytes without decoding or writing a temporary copy. */
    private fun fingerprintLocalText(doc: Uri): String {
        val digest = MessageDigest.getInstance("SHA-256")
        activity.contentResolver.openInputStream(doc)?.use { input ->
            val buffer = ByteArray(65536)
            var total = 0
            while (true) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                require(total <= MAX_TEXT_BYTES) { "TXT 文件过大：超过 256 MiB 导入上限" }
                digest.update(buffer, 0, count)
            }
        } ?: throw IllegalStateException("File is not readable")
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Stage bounded source bytes once, then decode without a full-book byte/string buffer.
     * The SHA-256 describes the same bytes as the returned decoded snapshot. */
    private fun prepareLocalText(doc: Uri, withFingerprint: Boolean = false): Any {
        val digest = MessageDigest.getInstance("SHA-256")
        val raw = File.createTempFile("local-raw-", ".tmp", activity.cacheDir)
        val decoded = File.createTempFile("local-utf8-", ".tmp", activity.cacheDir)
        try {
            activity.contentResolver.openInputStream(doc)?.use { input ->
                raw.outputStream().use { output ->
                    val buffer = ByteArray(65536)
                    var total = 0
                    while (true) {
                        if (Thread.currentThread().isInterrupted) throw InterruptedException()
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= MAX_TEXT_BYTES) { "TXT 文件过大：超过 256 MiB 导入上限" }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
            } ?: throw IllegalStateException("File is not readable")
            val encodings = listOf(Charsets.UTF_8, charset("GB18030"))
            for (encoding in encodings) {
                try {
                    InputStreamReader(raw.inputStream(), encoding.newDecoder()
                        .onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT)).use { reader ->
                        decoded.bufferedWriter(Charsets.UTF_8).use { writer ->
                            reader.copyTo(writer, 32768)
                        }
                    }
                    return if (withFingerprint) mapOf(
                        "path" to decoded.absolutePath,
                        "fingerprint" to digest.digest().joinToString("") { "%02x".format(it) },
                    ) else decoded.absolutePath
                } catch (_: CharacterCodingException) { }
            }
            throw IllegalArgumentException("TXT 解码失败：不是有效的 UTF-8 或 GB18030 文本")
        } catch (error: Exception) {
            decoded.delete()
            throw error
        } finally {
            raw.delete()
        }
    }

    /** 读取文本文件：严格 UTF-8 优先，失败则 GB18030，最后宽容回退。 */
    private fun readLocalText(doc: Uri): String {
        val bytes = ByteArrayOutputStream()
        activity.contentResolver.openInputStream(doc)?.use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                val count = input.read(buffer)
                if (count < 0) break
                if (bytes.size() + count > MAX_TEXT_BUFFER_BYTES) throw IllegalArgumentException("文本缓冲区超过 4 MiB，请使用流式导入")
                bytes.write(buffer, 0, count)
            }
        } ?: throw IllegalStateException("File is not readable")
        return decodeTextBytes(bytes.toByteArray())
    }

    private fun decodeTextBytes(bytes: ByteArray): String {
        try {
            return Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) { /* fall through to GB18030 */ }
        try {
            return charset("GB18030").newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: Exception) { /* fall through to lenient */ }
        return bytes.toString(Charsets.UTF_8)
    }

    /** 解码 Dart 传来的原始字节，支持自动识别 UTF-8/GB18030。 */
    private fun decodeLocalText(bytes: ByteArray?, encoding: String): String {
        if (bytes == null) throw IllegalArgumentException("缺少 bytes 参数")
        if (bytes.size > MAX_TEXT_BUFFER_BYTES) throw IllegalArgumentException("文本缓冲区超过 4 MiB，请使用流式导入")
        return when (encoding) {
            "gb18030" -> {
                // 强制 GB18030 解码（兼容 GBK）
                charset("GB18030").newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString()
            }
            "utf-8" -> {
                // 强制 UTF-8 解码
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString()
            }
            else -> {
                // auto: 先尝试 UTF-8，失败则用 GB18030
                decodeTextBytes(bytes)
            }
        }
    }

    private fun pdfPageCount(doc: Uri): Int {
        activity.contentResolver.openFileDescriptor(doc, "r")?.use { pfd ->
            PdfRenderer(pfd).use { renderer -> return renderer.pageCount }
        }
        throw IllegalStateException("PDF is not readable")
    }

    /** 按目标宽度渲染单页为 PNG（白色底），缓存命中则直接返回路径。 */
    private fun renderPdfPage(doc: Uri, page: Int, widthPx: Int): String {
        // 用 URI 的 SHA-256 前 16 字符作为目录名，避免 hashCode 碰撞（修复#11）。
        // 文件名包含宽度，避免不同渲染尺寸复用旧图。
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(doc.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }
            .substring(0, 16)
        val sub = File(File(activity.cacheDir, "local_pdf"), digest)
        if (!sub.isDirectory) sub.mkdirs()
        val w = widthPx.coerceIn(400, 2400)
        val out = File(sub, "p_${page}_w${w}.png")
        if (!out.isFile) {
            activity.contentResolver.openFileDescriptor(doc, "r")?.use { pfd ->
                PdfRenderer(pfd).use { renderer ->
                    require(page in 0 until renderer.pageCount) { "Page out of range" }
                    renderer.openPage(page).use { pg ->
                        val h = (w * pg.height / pg.width.toFloat()).roundToInt().coerceIn(400, 4200)
                        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        try {
                            Canvas(bmp).drawColor(Color.WHITE)
                            pg.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            // 先写临时文件再重命名，避免残缺缓存（修复#12）。
                            val tmp = File(sub, "p_${page}_w${w}.tmp")
                            var ok = false
                            FileOutputStream(tmp).use { fos ->
                                ok = bmp.compress(Bitmap.CompressFormat.PNG, 90, fos)
                                fos.flush()
                            }
                            if (!ok) throw IllegalStateException("Bitmap compress failed")
                            tmp.renameTo(out)
                        } finally {
                            // 确保位图释放（修复#12）。
                            if (!bmp.isRecycled) bmp.recycle()
                        }
                    }
                }
            } ?: throw IllegalStateException("PDF is not readable")
        }
        return out.absolutePath
    }

    /** 删除某 PDF 的全部渲染缓存。 */
    private fun clearPdfCache(doc: Uri): Boolean {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(doc.toString().toByteArray())
            .joinToString("") { "%02x".format(it) }
            .substring(0, 16)
        val sub = File(File(activity.cacheDir, "local_pdf"), digest)
        // 兼容旧版 hashCode 目录。
        val legacy = File(File(activity.cacheDir, "local_pdf"), Integer.toHexString(doc.toString().hashCode()))
        if (sub.isDirectory) sub.deleteRecursively()
        if (legacy.isDirectory && legacy != sub) legacy.deleteRecursively()
        return true
    }

    /** 删除 SAF 文档。provider 确认删除成功才算成功；FileNotFoundException
     * 不能证明文件不存在，保守返回 io_error / unconfirmed，保留本地记录，
     * 不再把“已不存在”当成删除成功。
     * 失败时返回结构化 code（permission / unsupported / delete_rejected /
     * invalid_uri / io_error / unknown），供 Dart 侧区分提示与兜底，
     * 不再把所有失败吞成同一句「删除失败」。 */
    private fun deleteLocalDocument(doc: Uri): Map<String, Any?> =
        localDeleteOutcome {
            DocumentsContract.deleteDocument(
                activity.contentResolver,
                doc
            )
        }

    /** 查询某 SAF 树 URI 的持久化读/写权限（persistedUriPermissions）。 */
    private fun queryTreePermission(treeUri: Uri): Map<String, Any?> {
        var persistedRead = false
        var persistedWrite = false
        for (permission in activity.contentResolver.persistedUriPermissions) {
            if (permission.uri == treeUri) {
                persistedRead = permission.isReadPermission
                persistedWrite = permission.isWritePermission
                break
            }
        }
        return mapOf(
            "persistedRead" to persistedRead,
            "persistedWrite" to persistedWrite
        )
    }

    /** 重命名 SAF 文档。成功返回新 URI 与 provider 确认的实际文件名。 */
    private fun renameLocalDocument(doc: Uri, newFileName: String, expectedFileName: String?): Map<String, Any?> =
        localRenameOutcome(
            originalUri = doc,
            newFileName = newFileName,
            expectedFileName = expectedFileName,
            readName = { uri ->
                activity.contentResolver.query(
                    uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
                )?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
            },
            rename = { uri, name ->
                DocumentsContract.renameDocument(activity.contentResolver, uri, name)
            },
        )

    /** 从 SAF 选择字体文件，单流校验并复制到应用私有目录，返回绝对路径。
     * 校验 sfnt 签名与表目录结构；任何失败都删除临时文件，不留孤立文件。 */
    private fun copyFontToPrivateDir(uri: Uri): String {
        val resolver = activity.contentResolver
        val dir = File(activity.filesDir, "fonts").apply { mkdirs() }
        val tmp = File.createTempFile("font_import_", ".tmp", dir)
        try {
            var ext = "ttf"
            resolver.openInputStream(uri)?.use { input ->
                // 头部 12 字节：签名(4) + numTables(2) + searchRange(2) + entrySelector(2) + rangeShift(2)。
                val header = ByteArray(12)
                var read = 0
                while (read < 12) {
                    val n = input.read(header, read, 12 - read)
                    if (n < 0) break
                    read += n
                }
                if (read < 12) throw IllegalStateException("文件太小，不是有效的字体文件")
                val sig = String(header, 0, 4, Charsets.ISO_8859_1)
                ext = when (sig) {
                    "\u0000\u0001\u0000\u0000" -> "ttf"
                    "OTTO" -> "otf"
                    // TTC 有独立的头部布局，暂不支持，明确拒绝。
                    else -> throw IllegalStateException("不是有效的字体文件（仅支持 TTF/OTF）")
                }
                val numTables = ((header[4].toInt() and 0xFF) shl 8) or (header[5].toInt() and 0xFF)
                if (numTables <= 0 || numTables > 64) {
                    throw IllegalStateException("字体表目录异常")
                }
                FileOutputStream(tmp).use { output ->
                    output.write(header, 0, read)
                    val buf = ByteArray(8192)
                    var total = 12L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > MAX_FONT_BYTES) {
                            throw IllegalStateException("字体文件过大（超过 100MB）")
                        }
                        output.write(buf, 0, n)
                    }
                    output.flush()
                }
            } ?: throw IllegalStateException("无法读取所选文件")
            // 校验表目录：每个表项 16 字节，offset/length 须在文件范围内。
            validateSfntTables(tmp)
            val dest = File(dir, "${safeFontBaseName(resolver, uri)}_${System.currentTimeMillis()}.$ext")
            if (!tmp.renameTo(dest)) throw IllegalStateException("保存字体失败")
            return dest.absolutePath
        } catch (e: Exception) {
            try { tmp.delete() } catch (_: Exception) {}
            throw e
        }
    }

    /** 校验 sfnt 表目录结构：表项数量合理，每表 offset/length 在文件范围内，
     * 且必须同时包含 head、name、maxp 三个必要表。 */
    private fun validateSfntTables(file: File) {
        val size = file.length()
        val numTables: Int
        val dir: ByteArray
        java.io.FileInputStream(file).use { input ->
            val header = ByteArray(12)
            var read = 0
            while (read < 12) {
                val n = input.read(header, read, 12 - read)
                if (n < 0) break
                read += n
            }
            if (read < 12) throw IllegalStateException("字体文件损坏")
            numTables = ((header[4].toInt() and 0xFF) shl 8) or (header[5].toInt() and 0xFF)
            if (numTables <= 0 || numTables > 64) {
                throw IllegalStateException("字体表目录异常")
            }
            val need = 12 + numTables * 16
            if (size < need) throw IllegalStateException("字体表目录不完整")
            dir = ByteArray(need)
            System.arraycopy(header, 0, dir, 0, 12)
            read = 12
            while (read < need) {
                val n = input.read(dir, read, need - read)
                if (n < 0) break
                read += n
            }
            if (read < need) throw IllegalStateException("字体表目录不完整")
        }
        val tags = mutableSetOf<String>()
        for (i in 0 until numTables) {
            val off = 12 + i * 16
            val tag = String(dir, off, 4, Charsets.ISO_8859_1)
            val tblOffset = ((dir[off + 8].toInt() and 0xFF).toLong() shl 24) or
                ((dir[off + 9].toInt() and 0xFF).toLong() shl 16) or
                ((dir[off + 10].toInt() and 0xFF).toLong() shl 8) or
                (dir[off + 11].toInt() and 0xFF).toLong()
            val tblLen = ((dir[off + 12].toInt() and 0xFF).toLong() shl 24) or
                ((dir[off + 13].toInt() and 0xFF).toLong() shl 16) or
                ((dir[off + 14].toInt() and 0xFF).toLong() shl 8) or
                (dir[off + 15].toInt() and 0xFF).toLong()
            if (tblOffset < 0 || tblLen < 0 || tblOffset + tblLen > size) {
                throw IllegalStateException("字体表数据越界")
            }
            tags.add(tag)
        }
        if (!tags.containsAll(setOf("head", "name", "maxp"))) {
            throw IllegalStateException("字体缺少必要表")
        }
    }

    private fun safeFontBaseName(resolver: android.content.ContentResolver, uri: Uri): String {
        var displayName: String? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) displayName = c.getString(0)
            }
        } catch (_: Exception) {
        }
        return (displayName?.substringBeforeLast('.')?.takeIf { it.isNotBlank() } ?: "font")
            .replace(Regex("[^A-Za-z0-9_\\-\\u4e00-\\u9fff]"), "_")
            .take(40)
    }

    /** Only documented record/index files from the explicitly selected tree.
     * Never read cert.wk8, account files, images or arbitrary nested folders. */
    private fun readLegacyTree(tree: Uri): Map<String, Any> {
        data class Document(val id: String, val name: String, val directory: Boolean, val modified: Long)
        fun children(id: String): List<Document> {
            val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            return activity.contentResolver.query(uri, columns, null, null, null)?.use { cursor ->
                val records = ArrayList<Document>()
                while (cursor.moveToNext()) {
                    check(records.size < 10000) { "Folder too large" }
                    records.add(Document(cursor.getString(0), cursor.getString(1),
                        cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, cursor.getLong(3)))
                }
                records
            } ?: throw IllegalStateException("Folder is not readable")
        }
        val root = children(DocumentsContract.getTreeDocumentId(tree))
        val saves = root.firstOrNull { it.directory && it.name == "saves" }?.let { children(it.id) } ?: root
        val records = saves.filter { !it.directory && it.name in setOf("bookshelf_local.wk8", "read_saves.wk8", "read_saves_v1.wk8", "search_history.wk8") }
        require(records.isNotEmpty()) { "No legacy records" }
        val indices = saves.firstOrNull { it.directory && it.name == "intro" }?.let { children(it.id) }
            ?.filter { !it.directory && Regex("[1-9][0-9]{0,9}-volume\\.xml").matches(it.name) } ?: emptyList()
        val output = LinkedHashMap<String, Any>()
        var total = 0
        var skipped = 0
        for (document in records + indices) {
            val content = activity.contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, document.id))?.use { input ->
                val bytes = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                var oversized = false
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (bytes.size() + count > MAX_BYTES || total + bytes.size() + count > 8 * 1024 * 1024) {
                        if (document in records) throw IllegalArgumentException("Records too large")
                        skipped++
                        oversized = true
                        break
                    }
                    bytes.write(buffer, 0, count)
                }
                if (oversized) null else bytes.toByteArray()
            } ?: continue
            try {
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(content)).toString()
                total += content.size
                output[document.name] = mapOf("text" to text, "modifiedAt" to document.modified)
            } catch (_: Exception) { skipped++ }
        }
        require(records.any { output.containsKey(it.name) }) { "No readable legacy records" }
        return mapOf("documents" to output, "skippedFiles" to skipped)
    }

    fun close() {
        requests.close()
        pending = null
        pendingFolder = null
        pendingFont = null
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        io.shutdownNow()
    }
}
