package org.mewx.wenku8_flutter

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Silent public-API probe in the QA package: no Activity, speak(), settings changes or book text. */
object SpeechFixture {
    @Suppress("DEPRECATION")
    fun run(context: Context, results: Bundle) {
        val main = Handler(Looper.getMainLooper())
        val services = context.packageManager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
        val engines = services.map { it.serviceInfo.packageName }.distinct().filter(SpeechLocalePolicy::supportsEngine)
        val engine = engines.firstOrNull()
        results.putString("engines", engines.joinToString(","))
        if (engine == null) {
            results.putString("stream", "SPEECH_FIXTURE_NO_ENGINE\n")
            return
        }
        var tts: TextToSpeech? = null
        val ready = CountDownLatch(1)
        var status = TextToSpeech.ERROR
        val file = File(context.cacheDir, "speech-fixture.wav")
        try {
            main.post { tts = TextToSpeech(context, { value -> status = value; ready.countDown() }, engine) }
            check(ready.await(20, TimeUnit.SECONDS)) { "initialization_timeout" }
            check(status == TextToSpeech.SUCCESS) { "initialization_status=$status" }
            val voices = tts!!.voices.orEmpty()
            val json = JSONArray()
            for (voice in voices) {
                json.put(JSONObject().put("id", voice.name).put("locale", voice.locale.toLanguageTag())
                    .put("networkRequired", voice.isNetworkConnectionRequired).put("quality", voice.quality)
                    .put("features", JSONArray(voice.features.orEmpty().toList())))
            }
            results.putString("engine", engine)
            results.putString("voices", json.toString())
            val voice = voices.filter { !it.isNetworkConnectionRequired && it.locale.language == "zh" &&
                !it.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED) }.maxByOrNull { it.quality }
            if (voice == null) {
                results.putString("stream", "SPEECH_FIXTURE_NO_INSTALLED_OFFLINE_CHINESE_VOICE\n")
                return
            }
            check(tts!!.setVoice(voice) == TextToSpeech.SUCCESS) { "set_voice_failed" }
            tts!!.setSpeechRate(1f)
            tts!!.setPitch(1f)
            val done = CountDownLatch(1)
            var error: String? = null
            tts!!.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) { done.countDown() }
                @Deprecated("Legacy callback")
                override fun onError(utteranceId: String?) { error = "synthesis_error"; done.countDown() }
                override fun onError(utteranceId: String?, errorCode: Int) { error = "synthesis_error=$errorCode"; done.countDown() }
            })
            check(tts!!.synthesizeToFile("夜色渐深，微风翻过书页。这是一段中文离线朗读测试。", Bundle(), file, "speech-fixture") == TextToSpeech.SUCCESS) { "request_rejected" }
            check(done.await(60, TimeUnit.SECONDS)) { "synthesis_timeout" }
            check(error == null) { error.orEmpty() }
            val header = ByteArray(12)
            file.inputStream().use { check(it.read(header) == 12) }
            check(String(header.copyOfRange(0, 4), Charsets.US_ASCII) == "RIFF" &&
                String(header.copyOfRange(8, 12), Charsets.US_ASCII) == "WAVE") { "invalid_wav" }
            check(file.length() > 100) { "empty_wav" }
            results.putString("selectedVoice", voice.name)
            results.putLong("audioBytes", file.length())
            results.putString("stream", "SPEECH_FIXTURE_VERIFIED=public_android_engine,declared_offline_chinese,silent_wav_synthesis\n")
        } finally {
            file.delete()
            val release = CountDownLatch(1)
            main.post { tts?.stop(); tts?.shutdown(); release.countDown() }
            release.await(5, TimeUnit.SECONDS)
        }
    }
}
