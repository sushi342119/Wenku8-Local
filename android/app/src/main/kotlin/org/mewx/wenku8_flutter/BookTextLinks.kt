package org.mewx.wenku8_flutter

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.util.UUID

/** Opaque local references: document URIs/paths never enter a sync bundle or log. */
internal class BookTextLinks(private val context: Context) {
    private val preferences = context.getSharedPreferences("linked_book_documents", 0)
    private val opened = mutableMapOf<String, java.io.Closeable>()
    private var closed = false
    private fun records() = JSONObject(preferences.getString("references", "{}")!!)
    private fun save(value: JSONObject) {
        check(preferences.edit().putString("references", value.toString()).commit()) { "原文件授权记录保存失败" }
    }
    fun remember(uri: Uri, grant: Uri? = null): String {
        val values = records()
        for (key in values.keys()) if (values.getJSONObject(key).getString("uri") == uri.toString()) {
            if (grant != null && values.getJSONObject(key).optString("grant") != grant.toString()) {
                values.getJSONObject(key).put("grant", grant.toString()); save(values)
            }
            return key
        }
        val key = UUID.randomUUID().toString()
        values.put(key, JSONObject().put("uri", uri.toString()).put("grant", grant?.toString() ?: ""))
        save(values)
        return key
    }
    fun usesGrant(uri: Uri): Boolean {
        val values = records()
        return values.keys().asSequence().any { values.getJSONObject(it).optString("grant") == uri.toString() }
    }
    fun release(reference: String) {
        val values = records()
        val old = values.optJSONObject(reference) ?: return
        values.remove(reference); save(values)
        val grant = old.optString("grant").takeIf { it.isNotEmpty() }?.let(Uri::parse) ?: return
        val scan = context.getSharedPreferences("book_scan_folders", 0).getString("tree", null)
        if (grant.toString() != scan && !usesGrant(grant)) try {
            context.contentResolver.releasePersistableUriPermission(grant, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) { /* Already revoked by the user. */ }
    }
    private fun source(reference: String): Uri = records().optJSONObject(reference)?.getString("uri")?.let(Uri::parse)
        ?: error("原文件授权已失效，请重新定位原文件")

    /** A live, read-only descriptor lease, not a second file or saved path.
     * Dart and native parsers share this process; the URI grant remains private.
     * Only text-index leases include a logical start offset for bounded positional reads.
     * Non-seekable providers need an explicit managed copy instead. */
    fun openDocument(reference: String, expectedSize: Long? = null, expectedModified: Long? = null,
        purpose: String? = null): Map<String, Any> {
        val uri = source(reference)
        val before = modified(uri)
        var owner: java.io.Closeable? = null
        try {
            val fd: Int
            val range: LinkedDocumentRange
            if (uri.scheme == "file") {
                val file = File(uri.path!!)
                val descriptor = android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                owner = descriptor
                val size = android.system.Os.fstat(descriptor.fileDescriptor).st_size
                range = linkedDocumentRange(0, size, size, purpose)
                fd = descriptor.fd
            } else {
                require(uri.scheme == "content") { "原文件位置有误，请重新定位" }
                val descriptor = context.contentResolver.openAssetFileDescriptor(uri, "r")
                    ?: error("无法读取原文件，请重新定位原文件")
                owner = descriptor
                range = linkedDocumentRange(descriptor.startOffset, descriptor.declaredLength,
                    if (descriptor.declaredLength >= 0) 0L else android.system.Os.fstat(descriptor.fileDescriptor).st_size,
                    purpose)
                android.system.Os.lseek(descriptor.fileDescriptor, range.offset, android.system.OsConstants.SEEK_SET)
                fd = descriptor.parcelFileDescriptor.fd
            }
            val size = range.size
            check((expectedSize == null || size == expectedSize) &&
                (expectedModified == null || before == expectedModified) && modified(uri) == before) {
                "原文件已变化，请重新定位原文件"
            }
            val key = UUID.randomUUID().toString()
            synchronized(opened) {
                check(!closed) { "文件页面已关闭，请重新打开书库" }
                opened[key] = owner!!; owner = null
            }
            val response = mutableMapOf<String, Any>("lease" to key, "size" to size, "modified" to before, "descriptor" to fd)
            if (purpose == "text-index") response["offset"] = range.offset
            return response
        } catch (failure: android.system.ErrnoException) {
            if (failure.errno == android.system.OsConstants.ESPIPE)
                error("这个文件提供方不支持原位读取，请选择「复制到应用」")
            throw java.io.IOException("无法读取原文件，请重新定位原文件", failure)
        } catch (failure: java.io.IOException) {
            if (failure.message.orEmpty().contains("ESPIPE") || failure.message.orEmpty().contains("Illegal seek", true))
                error("这个文件提供方不支持原位读取，请选择「复制到应用」")
            throw failure
        } finally { owner?.close() }
    }
    fun closeDocument(key: String) { synchronized(opened) { opened.remove(key) }?.close() }
    fun close() {
        val leases = synchronized(opened) { closed = true; opened.values.toList().also { opened.clear() } }
        leases.forEach { runCatching { it.close() } }
    }

    private fun modified(uri: Uri): Long = if (uri.scheme == "file") File(uri.path!!).lastModified()
        else if (!DocumentsContract.isDocumentUri(context, uri)) 0L else
        context.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else 0L
        } ?: 0L

    private fun <T> read(reference: String, expectedSize: Long? = null, expectedModified: Long? = null,
        action: (LinkedTextFile, Long) -> T): T {
        val uri = source(reference)
        val before = modified(uri)
        fun run(file: LinkedTextFile): T {
            check((expectedSize == null || file.size == expectedSize) &&
                (expectedModified == null || expectedModified == before)) { "原文件已变化，请重新定位原文件" }
            val result = action(file, before)
            check(modified(uri) == before) { "原文件已变化，请重新定位原文件" }
            return result
        }
        if (uri.scheme == "file") return FileInputStream(File(uri.path!!)).use {
            run(LinkedTextFile(it.channel, 0, it.channel.size()))
        }
        require(uri.scheme == "content") { "原文件位置有误，请重新定位" }
        try {
            return (context.contentResolver.openAssetFileDescriptor(uri, "r")
                ?: error("无法读取原文件，请重新定位原文件")).use { descriptor ->
                descriptor.createInputStream().use { input ->
                    val size = if (descriptor.declaredLength >= 0) descriptor.declaredLength
                        else input.channel.size() - descriptor.startOffset
                    run(LinkedTextFile(input.channel, descriptor.startOffset, size))
                }
            }
        } catch (failure: java.io.IOException) {
            if (failure.message.orEmpty().contains("ESPIPE") || failure.message.orEmpty().contains("Illegal seek", true))
                error("这个文件提供方不支持关联读取，请选择「复制到应用」")
            throw failure
        }
    }
    fun inspect(reference: String, encoding: String): Map<String, Any> = read(reference) { file, modified ->
        val result = file.inspect(encoding)
        mapOf("reference" to reference, "encoding" to result.encoding, "digest" to result.digest,
            "size" to file.size, "modified" to modified)
    }
    fun block(reference: String, encoding: String, offset: Long, size: Long, modified: Long): Map<String, Any> =
        read(reference, size, modified) { file, _ ->
            val result = file.block(offset, encoding)
            // Binary UTF-8 avoids StringCodec stripping a block-leading BOM.
            mapOf("textBytes" to result.text.toByteArray(Charsets.UTF_8), "next" to result.next)
        }
    fun bytes(reference: String, offset: Long, size: Long, modified: Long): ByteArray =
        read(reference, size, modified) { file, _ -> file.bytes(offset) }
}

internal data class LinkedDocumentRange(val offset: Long, val size: Long)

/** Text indexing uses bounded positional reads; archive callers still require a whole-file descriptor. */
internal fun linkedDocumentRange(startOffset: Long, declaredLength: Long, descriptorSize: Long,
    purpose: String? = null): LinkedDocumentRange {
    require(purpose == null || purpose == "text-index") { "原文件读取用途无效" }
    require(purpose == "text-index" || startOffset == 0L) { "这个文件提供方不支持原位读取，请选择「复制到应用」" }
    require(startOffset >= 0) { "原文件位置有误，请重新定位" }
    val size = if (declaredLength >= 0) declaredLength else {
        require(descriptorSize >= startOffset) { "原文件为空或超过 512 MiB" }
        descriptorSize - startOffset
    }
    require(size in 1..BookArchiveImport.MAX_ARCHIVE) { "原文件为空或超过 512 MiB" }
    require(startOffset <= Long.MAX_VALUE - size) { "原文件位置有误，请重新定位" }
    return LinkedDocumentRange(startOffset, size)
}
