package org.mewx.wenku8_flutter

import java.io.InputStream

internal class BookOpenMoveFailure(val code: String, message: String) : IllegalStateException(message)

internal fun bookOpenMoveAllowed(name: String, document: Boolean, writable: Boolean,
    supportsDelete: Boolean): Boolean = document && writable && supportsDelete &&
    (name.endsWith(".txt", true) || name.endsWith(".epub", true))

/** Deletion needs a complete transfer check, including providers with short reads. */
internal fun sameBookOpenBytes(source: InputStream, saved: InputStream): Boolean {
    fun fill(input: InputStream, buffer: ByteArray): Int {
        var count = 0
        while (count < buffer.size) {
            val read = input.read(buffer, count, buffer.size - count)
            if (read < 0) break
            if (read == 0) {
                val byte = input.read()
                if (byte < 0) break
                buffer[count++] = byte.toByte()
            } else count += read
        }
        return count
    }
    val original = ByteArray(64 * 1024)
    val copy = ByteArray(original.size)
    var nonempty = false
    while (true) {
        val count = fill(source, original)
        if (count != fill(saved, copy)) return false
        if (count == 0) return nonempty
        nonempty = true
        for (index in 0 until count) if (original[index] != copy[index]) return false
    }
}
