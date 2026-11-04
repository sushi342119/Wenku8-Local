package org.mewx.wenku8_flutter

import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.Charset
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest

/** Stateless decoder boundaries let the Dart directory use sparse byte/character
 * checkpoints. Only a bounded block is decoded; no converted book is saved. */
internal class LinkedTextFile(private val channel: FileChannel, private val base: Long, val size: Long) {
    data class Block(val text: String, val next: Long)
    data class Inspection(val encoding: String, val digest: String)
    private var failedAt = 0L

    init {
        require(size in 1..BookTextDecoder.MAX_TEXT) { "单本 TXT 需要在 128 MiB 以内" }
        channel.position(base) // A pipe/provider without seeking needs managed import.
    }

    fun bytes(offset: Long, count: Int = 128 * 1024): ByteArray {
        require(offset in 0..size && count in 1..128 * 1024)
        val buffer = ByteBuffer.allocate(minOf(count.toLong(), size - offset).toInt())
        channel.position(base + offset)
        while (buffer.hasRemaining()) {
            check(channel.read(buffer) > 0) { "原文件已变化，请重新定位原文件" }
        }
        return buffer.array()
    }

    fun block(offset: Long, encoding: String): Block = decodeBlock(offset, Charset.forName(encoding))

    private fun decodeBlock(offset: Long, charset: Charset, digest: MessageDigest? = null): Block {
        require(offset in 0 until size)
        val bytes = bytes(offset, 32 * 1024)
        val trims = if (offset + bytes.size < size) 0..3 else 0..0
        var firstFailure: CharacterCodingException? = null
        for (trim in trims) {
            val input = ByteBuffer.wrap(bytes, 0, bytes.size - trim)
            try {
                // A one-shot, strict decode must finish the complete code point.
                // Android ICU can retain half a surrogate internally when a
                // caller-sized CharBuffer overflows; that state cannot be lost
                // between independently seekable blocks or platform messages.
                val text = charset.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(input).toString()
                // A trimmed code point is read again by the next block. Hash
                // only bytes accepted by this strict decoder boundary.
                digest?.update(bytes, 0, bytes.size - trim)
                return Block(text, offset + bytes.size - trim)
            } catch (failure: CharacterCodingException) {
                if (firstFailure == null) { firstFailure = failure; failedAt = offset + input.position() }
                if (input.position() < bytes.size - 4 || trim == trims.last) throw firstFailure
            }
        }
        error("无法读取文本编码，请重新选择编码")
    }

    fun inspect(requested: String): Inspection {
        require(requested == "auto" || Charset.forName(requested) in
            listOf("UTF-8", "GB18030", "Big5", "Big5-HKSCS", "UTF-16LE", "UTF-16BE").map(Charset::forName)) { "不支持的文本编码" }
        var charset = BookTextDecoder.initialCharset(bytes(0, 3), requested)
        fun validate(): ByteArray {
            // Each attempt owns its digest: a failed UTF-8 prefix must not enter
            // the identity when automatic detection restarts with a legacy codec.
            val digest = MessageDigest.getInstance("SHA-256")
            var offset = 0L
            while (offset < size) offset = decodeBlock(offset, charset, digest).next
            return digest.digest()
        }
        val digest = try { validate() }
        catch (failure: CharacterCodingException) {
            if (requested != "auto" || charset != Charsets.UTF_8) throw failure
            val start = (failedAt - 16 * 1024).coerceAtLeast(0)
            charset = BookTextDecoder.legacyCharset(bytes(start, 64 * 1024))
            validate()
        }
        return Inspection(charset.name(), digest.joinToString("") { "%02x".format(it) })
    }
}
