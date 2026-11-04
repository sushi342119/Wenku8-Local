package org.mewx.wenku8_flutter

/** Only app-rendered bounded PNGs enter the image share/export path. */
internal object QuoteCardImage {
    fun valid(bytes: ByteArray?): Boolean {
        if (bytes == null || bytes.size < 33 || bytes.size > 12 * 1024 * 1024) return false
        val signature = byteArrayOf(0x89.toByte(), 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        if (!bytes.copyOfRange(0, 8).contentEquals(signature) || String(bytes, 12, 4, Charsets.US_ASCII) != "IHDR") return false
        fun dimension(at: Int): Long = (at until at + 4).fold(0L) { value, index -> (value shl 8) or (bytes[index].toLong() and 255) }
        val width = dimension(16)
        val height = dimension(20)
        return width in 1..4096 && height in 1..8192 && width * height <= 12_000_000
    }

    fun fileName(value: String?): String {
        val stem = (value ?: "文库摘录").removeSuffix(".png").replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "-").take(100)
        return "${stem.ifBlank { "文库摘录" }}.png"
    }
}
