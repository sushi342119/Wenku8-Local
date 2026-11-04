package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Intent
import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.os.Build
import android.provider.Settings
import android.Manifest
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** SAF for chosen folders; explicit system permission for optional shared-storage
 * scanning. Account credentials and private application files stay separate. */
class BookDocuments internal constructor(
    private val activity: Activity,
    private val imports: BookDocumentImportSession<Uri>,
    private val opens: BookOpenRequests,
) : MethodChannel.MethodCallHandler {
    private val io = Executors.newSingleThreadExecutor()
    private val preferences = activity.getSharedPreferences("book_documents", 0)
    private data class Pending(val method: String, val result: MethodChannel.Result, val deferred: Boolean = false, val linkText: Boolean = false, val linkOriginals: Boolean = false)
    private var pending: Pending? = null
    private var closed = false
    private val root = File(activity.cacheDir, "book-documents").apply { mkdirs() }
    private val importRoot get() = imports.root
    private val scanner = BookFolderScanner(activity)
    private val links = BookTextLinks(activity)
    companion object { private const val REQUEST = 8020; private const val ALL_REQUEST = 8021; private const val MAX_SYNC = 256L * 1024 * 1024 }

    private fun name(uri: Uri, fallback: String = "wenku8.wenku8sync"): String = activity.contentResolver.query(uri,
        arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    } ?: fallback

    private fun selected(): Uri = preferences.getString("sync_uri", null)?.let(Uri::parse)
        ?: throw IllegalStateException("请先选择云同步文件")

    private fun canWrite(uri: Uri): Boolean = activity.contentResolver.query(uri,
        arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
        it.moveToFirst() && (it.getInt(0) and DocumentsContract.Document.FLAG_SUPPORTS_WRITE) != 0
    } ?: false

    private fun copy(uri: Uri, target: File, max: Long) =
        copySelectedBookDocument(activity.contentResolver, uri, target, max)

    private fun file(path: String): File {
        val candidate = File(path).canonicalFile
        require(candidate.parentFile == root.canonicalFile && candidate.isFile) { "文件路径无效" }
        return candidate
    }

    // Network downloads live in a different private cache subtree. Permit it
    // for decoding only; sync writes retain their original strict root check.
    private fun bookTextFile(path: String): File {
        val candidate = File(path).canonicalFile
        val cloud = File(activity.cacheDir, "cloud-book-import").canonicalFile
        require(candidate.isFile && (candidate.parentFile == root.canonicalFile ||
            imports.initialized && candidate.parentFile == importRoot.canonicalFile ||
            candidate.path.startsWith(cloud.path + File.separator))) { "文件路径无效" }
        return candidate
    }

    private fun equal(a: File, b: File): Boolean {
        if (a.length() != b.length()) return false
        a.inputStream().use { left -> b.inputStream().use { right ->
            val x = ByteArray(65536); val y = ByteArray(65536)
            while (true) {
                val n = left.read(x); if (n < 0) return right.read() < 0
                var offset = 0
                while (offset < n) { val read = right.read(y, offset, n - offset); if (read < 0) return false; offset += read }
                for (i in 0 until n) if (x[i] != y[i]) return false
            }
        } }
    }

    private fun background(result: MethodChannel.Result, linked: Boolean = false, action: () -> Any?) {
        if (closed) { result.error("closed", "文件页面已关闭，请返回文库后重试", null); return }
        io.execute {
            try { val value = action(); activity.runOnUiThread {
                if (closed) result.error("closed", "文件页面已关闭，请返回文库后重试", null) else result.success(value)
            } }
            catch (error: Exception) { activity.runOnUiThread { result.error(if (error is BookOpenMoveFailure) error.code else "document", if (linked) bookImportMessage(error) else error.message ?: "文件操作失败，请重试", nativeErrorDetails(error)) } }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pendingBookOpen" -> background(result) { opens.pending() }
            "resolveBookOpen" -> background(result) {
                opens.resolve(call.argument<String>("id") ?: "", call.argument<Boolean>("copy") == true, links, imports)
            }
            "finishBookOpen" -> background(result) { opens.finish(call.argument<String>("id") ?: "", links); null }
            "deleteBookOpenSource" -> background(result) {
                opens.deleteSource(call.argument<String>("id") ?: "", call.argument<String>("path") ?: ""); null
            }
            "pickBookOpenReference" -> {
                if (pending != null) { result.error("busy", "请先完成当前文件选择", null); return }
                val initial = try { opens.initialUri(call.argument<String>("id") ?: "") }
                    catch (_: Exception) { result.error("document", "文件请求已结束，请重新打开", null); return }
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    if (Build.VERSION.SDK_INT >= 26) putExtra(DocumentsContract.EXTRA_INITIAL_URI, initial)
                }
                pending = Pending("pickOriginalReference", result, linkText = true)
                try { @Suppress("DEPRECATION") activity.startActivityForResult(intent, REQUEST) }
                catch (_: Exception) { pending = null; result.error("picker", "系统文件选择器不可用", null) }
            }
            "selectAllScan" -> {
                if (pending != null) { result.error("busy", "请先完成当前文件选择", null); return }
                if (scanner.canReadAll()) { background(result) { scanner.selectAll() }; return }
                pending = Pending(call.method, result)
                try {
                    if (Build.VERSION.SDK_INT >= 30) {
                        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:${activity.packageName}"))
                        @Suppress("DEPRECATION") activity.startActivityForResult(intent, ALL_REQUEST)
                    } else activity.requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), ALL_REQUEST)
                } catch (_: Exception) { pending = null; result.error("permission", "系统未提供共享存储授权，请选择指定文件夹", null) }
            }
            "pickBook", "pickBooks", "pickDictionaryFiles", "pickTextReference", "pickOriginalReference", "pickFont", "pickImage", "openSync", "createSync", "selectScanFolder" -> {
                if (pending != null) { result.error("busy", "请先完成当前文件选择", null); return }
                val create = call.method == "createSync"
                val folder = call.method == "selectScanFolder"
                val choosingImage = call.method == "pickImage"
                val choosingDictionaries = call.method == "pickDictionaryFiles"
                val choosingBooks = call.method == "pickBook" || call.method == "pickBooks"
                val linkText = call.method in setOf("pickTextReference", "pickOriginalReference") || call.argument<Boolean>("linkText") == true || call.argument<Boolean>("linkOriginals") == true
                val intent = Intent(if (folder) Intent.ACTION_OPEN_DOCUMENT_TREE else if (create) Intent.ACTION_CREATE_DOCUMENT else if ((choosingBooks && !linkText) || choosingImage || choosingDictionaries) Intent.ACTION_GET_CONTENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                    if (!folder) { addCategory(Intent.CATEGORY_OPENABLE); type = "*/*" }
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    if (!folder && call.method != "pickFont" && !choosingImage && !choosingDictionaries && !linkText) addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    if (choosingImage) type = "image/*"
                    if (create) { type = "application/octet-stream"; putExtra(Intent.EXTRA_TITLE, "文库同步.wenku8sync") }
                    if (call.method == "pickBook" || call.method == "pickBooks") {
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/*", "application/epub+zip", "application/zip", "application/x-zip-compressed", "application/x-mobipocket-ebook", "application/vnd.amazon.ebook", "application/pdf", "application/rtf", "application/xml", "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/octet-stream"))
                        if (call.method == "pickBooks") putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }
                    if (choosingDictionaries) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                pending = Pending(call.method, result, call.argument<Boolean>("deferred") == true, linkText, call.argument<Boolean>("linkOriginals") == true)
                try { @Suppress("DEPRECATION") activity.startActivityForResult(
                    if (folder || choosingBooks || choosingImage || choosingDictionaries) Intent.createChooser(intent, if (folder) "选择支持文件夹授权的应用" else if (choosingImage) "选择图片应用" else "选择文件应用") else intent,
                    REQUEST) }
                catch (_: Exception) { pending = null; result.error("picker", "系统文件选择器不可用", null) }
            }
            "scanFolderInfo" -> background(result) { scanner.info() }
            "setScanAutomatic" -> background(result) { scanner.setAutomatic(call.argument<Boolean>("value") == true); null }
            "disconnectScanFolder" -> background(result) { scanner.disconnect(); null }
            "scanBooks" -> background(result) { scanner.scan() }
            "scanFormats" -> background(result) { scanner.formats().toList() }
            "setScanFormats" -> background(result) { scanner.setFormats(call.argument<List<String>>("extensions") ?: emptyList()); null }
            "stageScanBook" -> background(result) { scanner.stage(call.argument<String>("token") ?: "", importRoot, ::copy) }
            "linkScanBook" -> background(result) { scanner.link(call.argument<String>("token") ?: "", links, importRoot, ::copy) }
            "inspectLinkedText" -> background(result, linked = true) { links.inspect(call.argument<String>("reference") ?: "", call.argument<String>("encoding") ?: "auto") }
            "readLinkedText" -> background(result, linked = true) { links.block(call.argument<String>("reference") ?: "", call.argument<String>("encoding") ?: "UTF-8",
                call.argument<Number>("offset")!!.toLong(), call.argument<Number>("size")!!.toLong(), call.argument<Number>("modified")!!.toLong()) }
            "readLinkedBytes" -> background(result, linked = true) { links.bytes(call.argument<String>("reference") ?: "",
                call.argument<Number>("offset")!!.toLong(), call.argument<Number>("size")!!.toLong(), call.argument<Number>("modified")!!.toLong()) }
            "releaseLinkedText" -> background(result) { links.release(call.argument<String>("reference") ?: ""); null }
            "openLinkedDocument" -> background(result, linked = true) { links.openDocument(call.argument<String>("reference") ?: "",
                call.argument<Number>("size")?.toLong(), call.argument<Number>("modified")?.toLong(), call.argument<String>("purpose")) }
            "closeLinkedDocument" -> background(result) { links.closeDocument(call.argument<String>("lease") ?: ""); null }
            "prepareLinkedDocument" -> background(result, linked = true) {
                val lease = links.openDocument(call.argument<String>("reference") ?: "")
                try {
                    BookArchiveImport(importRoot).apply { documents = BookMarkupImport(importRoot, BookPdfImport(activity, importRoot)::read) }
                        .prepare(call.argument<String>("name") ?: "", if (lease["descriptor"] is Int)
                            BookDocumentInput(lease["descriptor"] as Int, lease["size"] as Long)
                            else BookDocumentInput(File(lease["path"] as String)))
                } finally { links.closeDocument(lease["lease"] as String) }
            }
            "stagedTextReference" -> background(result) { links.remember(Uri.fromFile(bookTextFile(call.argument<String>("path") ?: ""))) }
            "stageImportBook" -> background(result) {
                try { imports.queue.stage(call.argument<String>("token") ?: "") }
                catch (error: Exception) { throw IllegalArgumentException(bookImportMessage(error), error) }
            }
            "markScanBook" -> background(result) { scanner.markImported(call.argument<String>("token") ?: ""); null }
            "finishBookScan" -> background(result) { scanner.finish(); null }
            "syncInfo" -> background(result) {
                val value = preferences.getString("sync_uri", null)
                if (value == null) null else mapOf("name" to name(Uri.parse(value)), "authority" to (Uri.parse(value).authority ?: ""), "created" to preferences.getBoolean("sync_new", false))
            }
            "releaseBooks" -> background(result) {
                for (path in (call.argument<List<String>>("paths") ?: emptyList()).distinct()) {
                    releaseSelectedBookDocument(path, root, if (imports.initialized) importRoot else null)
                }
                if (imports.initialized) imports.queue.release(call.argument<List<String>>("tokens") ?: emptyList())
                null
            }
            "prepareBook" -> background(result) {
                val source = bookTextFile(call.argument<String>("path") ?: "")
                val staging = if (imports.initialized && source.parentFile == importRoot.canonicalFile) importRoot else root
                BookArchiveImport(staging).apply { documents = BookMarkupImport(staging, BookPdfImport(activity, staging)::read) }
                    .prepare(call.argument<String>("name") ?: "", source)
            }
            "readSync" -> background(result) {
                val snapshot = File(root, "cloud-before.wenku8sync")
                copy(selected(), snapshot, MAX_SYNC)
                mapOf("path" to snapshot.path, "size" to snapshot.length(), "outputPath" to File(root, "cloud-next.wenku8sync").path)
            }
            "writeSync" -> background(result) {
                val target = selected()
                require(canWrite(target)) { "所选云文档不支持写入，请换一个文件" }
                val next = file(call.argument<String>("path") ?: "")
                val before = file(call.argument<String>("expectedPath") ?: "")
                require(next.length() in 1..MAX_SYNC) { "同步文件过大" }
                val fresh = File(root, "cloud-check.wenku8sync")
                copy(target, fresh, MAX_SYNC)
                check(equal(before, fresh)) { "云端文件已发生变化，请重新同步" }
                // Retain both recoverable snapshots before a provider write.
                val recovery = File(activity.filesDir, "sync-recovery").apply { mkdirs() }
                before.copyTo(File(recovery, "cloud-before.wenku8sync"), overwrite = true)
                next.copyTo(File(recovery, "cloud-next.wenku8sync"), overwrite = true)
                activity.contentResolver.openFileDescriptor(target, "rwt")?.use { fd ->
                    java.io.FileOutputStream(fd.fileDescriptor).use { output ->
                        next.inputStream().use { it.copyTo(output) }; output.flush()
                    }
                } ?: error("无法写入云端文件，恢复副本已保留")
                val after = File(root, "cloud-after.wenku8sync")
                copy(target, after, MAX_SYNC)
                check(equal(next, after)) { "云端写入未完整确认，恢复副本已保留" }
                check(preferences.edit().putBoolean("sync_new", false).commit())
                true
            }
            "disconnectSync" -> background(result) {
                preferences.getString("sync_uri", null)?.let { value ->
                    try { activity.contentResolver.releasePersistableUriPermission(Uri.parse(value),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) } catch (_: Exception) { }
                }
                check(preferences.edit().remove("sync_uri").remove("sync_new").commit()); null
            }
            "recoverSync" -> background(result) {
                val which = call.argument<String>("which")
                require(which in setOf("before", "next"))
                val recovery = File(activity.filesDir, "sync-recovery/cloud-$which.wenku8sync")
                if (!recovery.isFile) null else {
                    val copy = File(root, "recovery.wenku8sync"); recovery.copyTo(copy, overwrite = true); copy.path
                }
            }
            "decodeText" -> background(result) {
                val source = bookTextFile(call.argument<String>("path") ?: "")
                require(source.length() <= 40L * 1024 * 1024) { "单本 TXT 不能超过 40 MiB" }
                BookTextDecoder.decode(source.readBytes(), call.argument<String>("encoding") ?: "auto")
            }
            "decodeTextFile" -> background(result) {
                val source = bookTextFile(call.argument<String>("path") ?: "")
                val staging = if (imports.initialized && source.parentFile == importRoot.canonicalFile) importRoot else root
                val target = File.createTempFile("import-", ".source", staging)
                try { BookTextDecoder.normalize(source, target, call.argument<String>("encoding") ?: "auto") }
                catch (failure: Exception) {
                    target.delete()
                    if (failure is java.nio.charset.CharacterCodingException) error("文本编码无法识别，请在书库设置选择正确的 TXT 编码后重试")
                    throw IllegalArgumentException(bookImportMessage(failure), failure)
                }
                target.path
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request == ALL_REQUEST) { finishAllPermission(); return true }
        if (request != REQUEST) return false
        val operation = pending ?: return true
        pending = null
        if (code != Activity.RESULT_OK || data == null) { operation.result.success(null); return true }
        val uris = linkedSetOf<Uri>()
        if (operation.method == "pickBooks" || operation.method == "pickDictionaryFiles") data.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        }
        data.data?.let(uris::add)
        if (uris.isEmpty()) { operation.result.success(null); return true }
        val uri = uris.first()
        background(operation.result) {
            if (operation.method == "selectScanFolder") {
                scanner.select(uri, data.flags)
            } else if (operation.method == "pickImage") {
                val display = name(uri, "图片")
                val target = File.createTempFile("artwork-", ".image", root)
                try { copy(uri, target, 20L * 1024 * 1024) }
                catch (error: Exception) { target.delete(); throw error }
                mapOf("name" to display, "path" to target.path)
            } else if (operation.method == "pickFont") {
                val display = name(uri)
                require(display.substringAfterLast('.').lowercase() in setOf("ttf", "otf")) { "请选择 TTF 或 OTF 字体" }
                val target = File.createTempFile("import-", ".source", root)
                try { copy(uri, target, 32L * 1024 * 1024) }
                catch (error: Exception) { target.delete(); throw error }
                mapOf("name" to display, "path" to target.path)
            } else if (operation.method == "pickDictionaryFiles") {
                require(uris.size <= 64) { "一次最多选择 64 个词典文件" }
                uris.map { selected ->
                    var display = "所选词典"
                    var target: File? = null
                    try {
                        display = name(selected)
                        require(dictionaryFileName(display)) { "请选择 MDX、MDD、MOBI 词典、StarDict 文件或 ZIP 词典包" }
                        val destination = File.createTempFile("import-", ".source", root)
                        target = destination
                        copy(selected, destination, 512L * 1024 * 1024)
                        mapOf("name" to display, "path" to destination.path)
                    } catch (error: Exception) {
                        target?.delete()
                        mapOf("name" to display, "error" to (error.message ?: "无法读取所选词典"))
                    }
                }
            } else if (operation.method == "pickBooks") {
                uris.map { selected ->
                    var display = "所选文件"
                    var target: File? = null
                    try {
                        display = name(selected)
                        require(BookArchiveImport.supported(display)) { "请选择支持的电子书或文档" }
                        if (operation.linkOriginals && BookArchiveImport.supported(display) || operation.linkText && display.endsWith(".txt", true)) {
                            try { activity.contentResolver.takePersistableUriPermission(selected, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                            catch (_: SecurityException) { error("文件提供方未授予长期读取权限，请选择「复制到应用」导入") }
                            return@map mapOf("name" to display, "reference" to links.remember(selected, selected))
                        }
                        if (operation.deferred) return@map imports.queue.select(selected, display, BookArchiveImport.limit(display))
                        val destination = File.createTempFile("import-", ".source", root)
                        target = destination
                        copy(selected, destination, BookArchiveImport.limit(display))
                        mapOf("name" to display, "path" to destination.path)
                    } catch (error: Exception) {
                        target?.delete()
                        mapOf("name" to display, "error" to bookImportMessage(error))
                    }
                }
            } else if (operation.method in setOf("pickTextReference", "pickOriginalReference")) {
                val display = name(uri)
                require(if (operation.method == "pickTextReference") display.endsWith(".txt", true) else BookArchiveImport.supported(display)) { "请选择原来的书籍文件" }
                activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                mapOf("name" to display, "reference" to links.remember(uri, uri))
            } else if (operation.method == "pickBook") {
                val display = name(uri)
                require(BookArchiveImport.supported(display)) { "请选择支持的电子书或文档" }
                val target = File(root, "import-source")
                copy(uri, target, BookArchiveImport.limit(display))
                mapOf("name" to display, "path" to target.path)
            } else {
                require(canWrite(uri)) { "此云文档不支持写入，请选择可编辑的同步文件" }
                val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                require(flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0 && flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0) { "云端未授予读写权限，请重新选择" }
                activity.contentResolver.takePersistableUriPermission(uri, flags)
                check(preferences.edit().putString("sync_uri", uri.toString()).putBoolean("sync_new", operation.method == "createSync").commit())
                mapOf("name" to name(uri), "authority" to (uri.authority ?: ""), "created" to (operation.method == "createSync"))
            }
        }
        return true
    }
    fun onRequestPermissionsResult(request: Int): Boolean {
        if (request != ALL_REQUEST) return false
        finishAllPermission()
        return true
    }
    private fun finishAllPermission() {
        val operation = pending?.takeIf { it.method == "selectAllScan" } ?: return
        pending = null
        if (scanner.canReadAll()) background(operation.result) { scanner.selectAll() }
        else operation.result.success(null)
    }
    fun close() {
        links.close()
        closed = true; pending?.result?.error("closed", "页面已关闭，请重试", null); pending = null
        io.execute {
            try { scanner.finish() } catch (_: Exception) { /* The next scan safely retries unacknowledged files. */ }
        }
        io.shutdown()
    }
}

/** File-name filtering is only a picker guard; the Dart importer validates data. */
internal fun dictionaryFileName(name: String): Boolean =
    Regex("\\.(mdx|mdd|mobi|ifo|idx(?:\\.gz)?|dict(?:\\.dz)?|syn|zip)$", RegexOption.IGNORE_CASE).containsMatchIn(name)

internal fun releaseSelectedBookDocument(path: String, pickerRoot: File, importRoot: File? = null) {
    val source = File(path).canonicalFile
    val fromPicker = source.parentFile == pickerRoot.canonicalFile
    val bookCopy = source.name.startsWith("import-") && source.name.endsWith(".source") &&
        (fromPicker || importRoot != null && source.parentFile == importRoot.canonicalFile)
    // pickImage stages artwork-*.image in the picker cache. The durable
    // background/cover and the selected original are never release targets.
    val imageCopy = fromPicker && source.name.startsWith("artwork-") && source.name.endsWith(".image")
    require(bookCopy || imageCopy) { "文件路径无效" }
    check(!source.exists() || source.isFile && source.delete()) { "清理临时文件失败" }
}

internal fun copySelectedBookDocument(resolver: ContentResolver, uri: Uri, target: File, max: Long) {
    val partial = File(target.path + ".part")
    try {
        resolver.openInputStream(uri)?.use { input ->
            partial.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024); var size = 0L
                while (true) {
                    val count = input.read(buffer); if (count < 0) break
                    size += count; require(size <= max) { "文件超过 ${max / (1024 * 1024)} MiB 大小限制" }
                    output.write(buffer, 0, count)
                }
                output.fd.sync()
            }
        } ?: error("无法读取所选文件")
        check(partial.renameTo(target)) { "保存临时文件失败" }
    } finally { partial.delete() }
}
