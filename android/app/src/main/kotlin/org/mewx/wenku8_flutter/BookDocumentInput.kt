package org.mewx.wenku8_flutter

import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream
import java.util.zip.ZipException

/** Reopen a granted descriptor, not the underlying scoped-storage path. Each
 * stream owns its duplicate and uses positional reads, including nested DOCX
 * image reads while the XML stream remains open. */
internal class BookDocumentInput private constructor(val file: File?, val descriptor: Int?, val size: Long) {
    constructor(file: File) : this(file, null, file.length())
    constructor(descriptor: Int, size: Long) : this(null, descriptor, size)
    fun length() = size
    fun inputStream(): InputStream {
        file?.let { return it.inputStream() }
        val owner = ParcelFileDescriptor.AutoCloseInputStream(ParcelFileDescriptor.fromFd(descriptor!!))
        return object : InputStream() {
            private var position = 0L
            override fun read(): Int { val byte = ByteArray(1); return if (read(byte) < 0) -1 else byte[0].toInt() and 255 }
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                if (length == 0) return 0
                if (position >= size) return -1
                val count = owner.channel.read(ByteBuffer.wrap(bytes, offset, minOf(length.toLong(), size - position).toInt()), position)
                if (count > 0) position += count
                return count
            }
            override fun skip(amount: Long): Long {
                val count = minOf(maxOf(0L, amount), size - position); position += count; return count
            }
            override fun close() = owner.close()
        }
    }
    fun zip(): BookDocumentZip = file?.let { BookDocumentZip.file(it) } ?: BookDocumentZip.stream(this)
}

/** ZipFile remains the fast path for managed files. SAF archives use bounded
 * ZipInputStreams; required converted resources are saved, never the raw ZIP. */
internal abstract class BookDocumentZip : Closeable {
    abstract val entries: List<ZipEntry>
    fun getEntry(name: String) = entries.firstOrNull { it.name == name }
    abstract fun getInputStream(entry: ZipEntry): InputStream
    open fun readEntries(selected: List<ZipEntry>, read: (ZipEntry, InputStream) -> Unit) {
        for (entry in selected) getInputStream(entry).use { read(entry, it) }
    }
    companion object {
        fun file(file: File): BookDocumentZip {
            val zip = try { ZipFile(file, Charsets.UTF_8) } catch (_: ZipException) { ZipFile(file, Charset.forName("GB18030")) }
            return object : BookDocumentZip() {
                override val entries = zip.entries().toList()
                override fun getInputStream(entry: ZipEntry) = zip.getInputStream(entry)
                override fun close() = zip.close()
            }
        }
        fun stream(source: BookDocumentInput): BookDocumentZip {
            fun opened(charset: Charset) = ZipInputStream(source.inputStream(), charset)
            fun index(charset: Charset): List<ZipEntry> = opened(charset).use { zip ->
                val result = mutableListOf<ZipEntry>(); val bytes = ByteArray(65536); var expanded = 0L
                while (true) {
                    val entry = zip.nextEntry ?: break
                    require(result.size < 12000) { "压缩包文件过多" }
                    while (true) {
                        val count = zip.read(bytes); if (count < 0) break
                        expanded += count; require(expanded <= 1024L * 1024 * 1024) { "压缩包解压后超过 1 GiB" }
                    }
                    result += ZipEntry(entry); zip.closeEntry()
                }
                result
            }
            var charset = Charsets.UTF_8
            val entries = try { index(charset) } catch (failure: IllegalArgumentException) {
                if (failure.cause !is java.nio.charset.CharacterCodingException) throw failure
                charset = Charset.forName("GB18030"); index(charset)
            }
            return object : BookDocumentZip() {
                override val entries = entries
                override fun readEntries(selected: List<ZipEntry>, read: (ZipEntry, InputStream) -> Unit) {
                    val wanted = selected.toSet()
                    opened(charset).use { zip ->
                        var at = 0
                        while (zip.nextEntry != null) {
                            val entry = entries[at++]
                            if (entry in wanted) read(entry, object : java.io.FilterInputStream(zip) {
                                override fun close() = Unit
                            })
                            zip.closeEntry()
                        }
                    }
                }
                override fun getInputStream(entry: ZipEntry): InputStream {
                    val zip = opened(charset)
                    try {
                        while (true) {
                            val candidate = zip.nextEntry ?: error("压缩包中的资源已不存在")
                            if (candidate.name == entry.name) return zip
                            zip.closeEntry()
                        }
                    } catch (failure: Exception) { zip.close(); throw failure }
                }
                override fun close() = Unit
            }
        }
    }
}
