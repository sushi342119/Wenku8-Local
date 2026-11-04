package org.mewx.wenku8_flutter

import java.io.File
import java.io.InputStreamReader
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import org.mozilla.universalchardet.UniversalDetector

/** Bounded buffers, including charset fallback. No whole-book Java String or
 * platform-channel payload is needed for large TXT imports. */
internal object BookTextDecoder {
    const val MAX_TEXT = 128L * 1024 * 1024
    private const val SAMPLE_BYTES = 64 * 1024
    private val encodings = setOf("auto", "UTF-8", "GB18030", "Big5", "Big5-HKSCS", "UTF-16LE", "UTF-16BE")

    internal fun initialCharset(prefix: ByteArray, requested: String): Charset {
        return when {
        requested != "auto" -> Charset.forName(requested)
        prefix.size >= 2 && prefix[0] == 0xff.toByte() && prefix[1] == 0xfe.toByte() -> Charsets.UTF_16LE
        prefix.size >= 2 && prefix[0] == 0xfe.toByte() && prefix[1] == 0xff.toByte() -> Charsets.UTF_16BE
        else -> Charsets.UTF_8
        }
    }

    // Keep the UTF-8 fast path and the existing GB18030 fallback. Statistical
    // detection is only needed to distinguish legacy Traditional Chinese TXT.
    internal fun legacyCharset(sample: ByteArray, start: Int = 0, length: Int = sample.size): Charset {
        val detector = UniversalDetector(null)
        detector.handleData(sample, start, length)
        detector.dataEnd()
        return Charset.forName(if (detector.detectedCharset?.startsWith("BIG5", ignoreCase = true) == true) "Big5-HKSCS" else "GB18030")
    }

    /** Preserve the older, small-text bridge's explicit Charset contract. */
    fun decode(bytes: ByteArray, requested: String = "auto"): String {
        val charset = initialCharset(bytes, requested)
        val input = ByteBuffer.wrap(bytes)
        fun text(encoding: Charset): String = encoding.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(input).toString().removePrefix("\uFEFF")
        return try { text(charset) }
        catch (failure: CharacterCodingException) {
            if (requested != "auto" || charset != Charsets.UTF_8) throw failure
            val start = (input.position() - 16 * 1024).coerceAtLeast(0)
            val encoding = legacyCharset(bytes, start, minOf(SAMPLE_BYTES, bytes.size - start))
            input.rewind()
            text(encoding)
        }
    }

    fun normalize(source: File, target: File, requested: String = "auto") {
        normalize(BookDocumentInput(source), target, requested)
    }
    fun normalize(source: BookDocumentInput, target: File, requested: String = "auto") {
        require(source.length() in 1..MAX_TEXT) { "单本 TXT 需要在 128 MiB 以内" }
        require(requested in encodings) { "不支持的文本编码" }
        val prefix = source.inputStream().use { input -> ByteArray(3).also { input.read(it) } }
        val charset = initialCharset(prefix, requested)
        var readThrough = 0L
        fun decode(encoding: Charset) {
            val decoder = encoding.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
            val raw = source.inputStream()
            var consumed = 0L
            val counted = object : java.io.FilterInputStream(raw) {
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                    val n = super.read(bytes, offset, length); if (n > 0) consumed += n; return n
                }
            }
            counted.use { input ->
                InputStreamReader(input, decoder).use { reader ->
                    try {
                        target.bufferedWriter(Charsets.UTF_8, 64 * 1024).use { writer ->
                            val buffer = CharArray(32 * 1024)
                            var first = true
                            while (true) {
                                val count = reader.read(buffer)
                                if (count < 0) break
                                val start = if (first && count > 0 && buffer[0] == '\uFEFF') 1 else 0
                                if (count > 0) first = false
                                writer.write(buffer, start, count - start)
                            }
                        }
                    } catch (failure: CharacterCodingException) {
                        readThrough = consumed
                        throw failure
                    }
                }
            }
        }
        try {
            try { decode(charset) }
            catch (failure: CharacterCodingException) {
                if (requested != "auto" || charset != Charsets.UTF_8) throw failure
                // Sample near the first non-UTF-8 block, not an arbitrarily long
                // ASCII preface. No whole-file allocation or extra full scan.
                val sample = source.inputStream().use { file ->
                    val start = (readThrough - 16 * 1024).coerceAtLeast(0)
                    var skipped = 0L
                    while (skipped < start) { val n = file.skip(start - skipped); if (n <= 0) break; skipped += n }
                    val bytes = ByteArray(minOf(SAMPLE_BYTES.toLong(), source.length() - skipped).toInt())
                    var read = 0
                    while (read < bytes.size) { val n = file.read(bytes, read, bytes.size - read); if (n < 0) break; read += n }
                    bytes.copyOf(read)
                }
                decode(legacyCharset(sample))
            }
        } catch (failure: Exception) { target.delete(); throw failure }
    }
}
