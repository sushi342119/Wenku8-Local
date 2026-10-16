package org.mewx.wenku8_flutter

import java.util.Locale

/** Public Android TTS engines and ISO Chinese locale metadata only. */
internal object SpeechLocalePolicy {
    private val chineseLanguages = setOf("zh", "chi", "zho")
    fun supportsEngine(id: String?): Boolean = !id.isNullOrBlank() &&
        listOf("com.oplus.", "com.oppo.", "com.heytap.").none { id.startsWith(it) }
    fun chineseTag(locale: Locale): String? {
        val language = locale.language.lowercase(Locale.ROOT)
        if (language !in chineseLanguages) return null
        val parts = locale.toLanguageTag().split('-')
        val suffix = parts.drop(1).joinToString("-")
        return if (suffix.isEmpty()) "zh-CN" else "zh-$suffix"
    }
}
