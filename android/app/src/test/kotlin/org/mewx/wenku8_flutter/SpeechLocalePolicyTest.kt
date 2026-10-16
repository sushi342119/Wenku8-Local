package org.mewx.wenku8_flutter

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechLocalePolicyTest {
    @Test fun isoLanguageIsChinese() {
        assertEquals("zh-CN", SpeechLocalePolicy.chineseTag(Locale("chi")))
        assertEquals("zh-CN", SpeechLocalePolicy.chineseTag(Locale("zho")))
    }

    @Test fun standardScriptAndRegionRemainIntact() {
        assertEquals("zh-Hant-HK", SpeechLocalePolicy.chineseTag(Locale.forLanguageTag("zh-Hant-HK")))
        assertEquals("zh-TW", SpeechLocalePolicy.chineseTag(Locale("chi", "TW")))
        assertEquals("zh-CN", SpeechLocalePolicy.chineseTag(Locale.SIMPLIFIED_CHINESE))
    }

    @Test fun vendorAliasesAndOtherLanguagesAreNotChinese() {
        assertNull(SpeechLocalePolicy.chineseTag(Locale("chn")))
        assertNull(SpeechLocalePolicy.chineseTag(Locale("usa")))
        assertNull(SpeechLocalePolicy.chineseTag(Locale.US))
        assertNull(SpeechLocalePolicy.chineseTag(Locale.JAPANESE))
        assertNull(SpeechLocalePolicy.chineseTag(Locale.ROOT))
    }

    @Test fun retiredEnginesCannotBeInitializedEvenByDirectChannelCalls() {
        for (engine in listOf("com.oplus.ttsaccessibilityengine", "com.oppo.tts", "com.heytap.speech", "", null))
            assertFalse(SpeechLocalePolicy.supportsEngine(engine))
        assertTrue(SpeechLocalePolicy.supportsEngine("org.example.tts"))
    }
}
