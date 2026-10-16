package org.mewx.wenku8_flutter

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** Public Android TTS only. File synthesis never plays sound or invokes private voice-assistant APIs. */
class SystemSpeechPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    // Vendor engine Binder calls and voice-data loading never block UI rendering.
    private val speechWorker = Executors.newSingleThreadExecutor { task -> Thread(task, "wenku-system-speech").apply { isDaemon = true } }
    private var session: TextToSpeech? = null
    private var engine: String? = null
    private var initializing = false
    private val waiters = mutableListOf<(TextToSpeech?, String?) -> Unit>()
    @Volatile private var closed = false
    private data class Job(val id: String, val file: File, val result: MethodChannel.Result)
    private var job: Job? = null
    private var initTimeout: Runnable? = null
    private var synthTimeout: Runnable? = null
    @Volatile private var initEpoch = 0
    @Volatile private var synthEpoch = 0
    private var pendingSynthesis: String? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/system_speech")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        closed = true
        initEpoch++
        synthEpoch++
        pendingResult?.error("TTS_CANCELLED", "合成已取消", null)
        cancelJob("语音引擎已关闭")
        completeInit(null, "语音引擎已关闭")
        shutdownSession()
        session = null
        speechWorker.shutdown()
        channel.setMethodCallHandler(null)
    }

    @Suppress("DEPRECATION")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engines" -> {
                val services = context.packageManager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
                result.success(services.filter { SpeechLocalePolicy.supportsEngine(it.serviceInfo.packageName) }.map { info ->
                    val name = info.serviceInfo.packageName
                    mapOf("id" to name, "name" to info.loadLabel(context.packageManager).toString())
                }.distinctBy { it["id"] })
            }
            "voices" -> withEngine(call.argument<String>("engine"), result) { tts ->
                val epoch = initEpoch
                speechWorker.execute {
                    try {
                        val voices = tts.voices.orEmpty().map { voice -> mapOf(
                            "id" to voice.name, "locale" to (SpeechLocalePolicy.chineseTag(voice.locale) ?: voice.locale.toLanguageTag()),
                            "quality" to voice.quality, "latency" to voice.latency,
                            "networkRequired" to voice.isNetworkConnectionRequired,
                            "features" to voice.features.orEmpty().toList(),
                        ) }
                        main.post {
                            if (closed || epoch != initEpoch) result.error("TTS_CANCELLED", "音色检测已取消，请重新检测", null)
                            else result.success(voices)
                        }
                    } catch (_: Exception) { main.post { result.error("TTS_VOICE", "读取系统音色失败，请重新检测", null) } }
                }
            }
            "settings" -> {
                try {
                    context.startActivity(Intent("com.android.settings.TTS_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("TTS_SETTINGS", "请在手机设置搜索文字转语音，安装中文语音数据后重新检测", null)
                }
            }
            "synthesize" -> synthesize(call, result)
            "cancel" -> {
                val id = call.argument<String>("requestId")
                if (id != null && pendingSynthesis == id) {
                    synthEpoch++
                    pendingResult?.error("TTS_CANCELLED", "合成已取消", null)
                    cancelJob("合成已取消")
                    if (initializing) {
                        initEpoch++
                        shutdownSession()
                        session = null
                        engine = null
                        completeInit(null, "合成已取消")
                    }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun withEngine(id: String?, result: MethodChannel.Result, action: (TextToSpeech) -> Unit) {
        if (!SpeechLocalePolicy.supportsEngine(id) || closed) { result.error("TTS_ENGINE", "请选择受支持的系统语音引擎", null); return }
        @Suppress("DEPRECATION")
        val installed = context.packageManager.queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
            .any { it.serviceInfo.packageName == id }
        if (!installed) { result.error("TTS_ENGINE", "该系统语音引擎尚未安装，请重新检测", null); return }
        if (job != null) { result.error("TTS_BUSY", "系统语音正在准备上一段", null); return }
        if (engine == id && !initializing && session != null) { action(session!!); return }
        if (initializing && engine != id) { result.error("TTS_BUSY", "系统语音引擎正在切换", null); return }
        waiters.add { tts, error ->
            if (tts == null) result.error("TTS_INIT", error ?: "语音引擎尚未就绪", null)
            else try { action(tts) } catch (_: Exception) { result.error("TTS_VOICE", "读取系统音色失败，可重新检测", null) }
        }
        if (initializing) return
        shutdownSession()
        session = null
        engine = id
        initializing = true
        val epoch = ++initEpoch
        initTimeout = Runnable {
            if (initializing) {
                shutdownSession(); session = null
                completeInit(null, "系统语音初始化超时，请检查该引擎的语音数据")
            }
        }.also { main.postDelayed(it, 15_000) }
        session = TextToSpeech(context, { status -> main.post {
            if (!initializing || closed || epoch != initEpoch) return@post
            if (status == TextToSpeech.SUCCESS) completeInit(session, null)
            else { shutdownSession(); session = null; completeInit(null, "系统语音引擎初始化失败") }
        } }, id)
    }
    private fun completeInit(tts: TextToSpeech?, error: String?) {
        initTimeout?.let(main::removeCallbacks)
        initTimeout = null
        initializing = false
        val callbacks = waiters.toList()
        waiters.clear()
        callbacks.forEach { it(tts, error) }
    }

    private fun synthesize(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<String>("requestId").orEmpty()
        val text = call.argument<String>("text").orEmpty()
        val voiceName = call.argument<String>("voice").orEmpty()
        val path = call.argument<String>("path").orEmpty()
        val file = try { File(path).canonicalFile } catch (_: Exception) { null }
        if (!requestId.matches(Regex("[a-f0-9]{32}")) || text.isBlank() || text.length > minOf(TextToSpeech.getMaxSpeechInputLength(), 3500) ||
            file == null || !file.path.startsWith(context.cacheDir.canonicalPath + File.separator) ||
            !file.name.matches(Regex("[a-f0-9]{64}\\.wav\\.part"))) {
            result.error("TTS_INPUT", "语音文本或缓存位置无效", null); return
        }
        if (pendingSynthesis != null || job != null) { result.error("TTS_BUSY", "系统语音正在准备上一段", null); return }
        val epoch = ++synthEpoch
        pendingSynthesis = requestId
        var completed = false
        val guarded = object : MethodChannel.Result {
            private fun complete(action: () -> Unit) {
                if (completed) return
                completed = true
                if (pendingSynthesis == requestId) { pendingSynthesis = null; pendingResult = null }
                synthTimeout?.let(main::removeCallbacks)
                synthTimeout = null
                action()
            }
            override fun success(value: Any?) = complete { result.success(value) }
            override fun error(code: String, message: String?, details: Any?) = complete { result.error(code, message, details) }
            override fun notImplemented() = complete { result.notImplemented() }
        }
        pendingResult = guarded
        synthTimeout = Runnable {
            if (pendingSynthesis == requestId) {
                synthEpoch++
                guarded.error("TTS_TIMEOUT", "系统语音合成超时，请重试或重新检测音色", null)
                cancelJob("系统语音合成超时")
            }
        }.also { main.postDelayed(it, 30_000) }
        withEngine(call.argument<String>("engine"), guarded) { tts ->
            if (epoch != synthEpoch || closed || completed) { guarded.error("TTS_CANCELLED", "合成已取消", null); return@withEngine }
            speechWorker.execute {
                try {
                    if (epoch != synthEpoch || closed) return@execute
                    val voice = tts.voices.orEmpty().firstOrNull { it.name == voiceName }
                    if (voice == null || voice.isNetworkConnectionRequired || SpeechLocalePolicy.chineseTag(voice.locale) == null ||
                        voice.features.orEmpty().contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) {
                        main.post { guarded.error("TTS_OFFLINE", "该音色没有可用的离线中文语音数据，请重新检测或安装语音数据", null) }
                        return@execute
                    }
                    if (tts.setVoice(voice) != TextToSpeech.SUCCESS) {
                        main.post { guarded.error("TTS_VOICE", "该系统音色暂未就绪", null) }; return@execute
                    }
                    tts.setSpeechRate(1f)
                    tts.setPitch(1f)
                    file.parentFile?.mkdirs()
                    file.delete()
                    main.post {
                        if (epoch != synthEpoch || closed || completed) { file.delete(); return@post }
                        job = Job(requestId, file, guarded)
                        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                            override fun onStart(utteranceId: String?) = Unit
                            override fun onDone(utteranceId: String?) { main.post { finishJob(utteranceId, null) } }
                            @Deprecated("Legacy engine callback")
                            override fun onError(utteranceId: String?) { main.post { finishJob(utteranceId, "这一段离线语音合成失败", "TTS_CONTENT") } }
                            override fun onError(utteranceId: String?, errorCode: Int) {
                                val code = if (errorCode == TextToSpeech.ERROR_SYNTHESIS || errorCode == TextToSpeech.ERROR_INVALID_REQUEST || errorCode == TextToSpeech.ERROR)
                                    "TTS_CONTENT" else "TTS_SYNTH"
                                main.post { finishJob(utteranceId, "离线语音合成失败（$errorCode）", code) }
                            }
                            override fun onStop(utteranceId: String?, interrupted: Boolean) { main.post { finishJob(utteranceId, "合成已取消", "TTS_CANCELLED") } }
                        })
                        speechWorker.execute {
                            if (epoch != synthEpoch || closed) return@execute
                            try {
                                if (tts.synthesizeToFile(text, Bundle(), file, requestId) != TextToSpeech.SUCCESS)
                                    main.post { finishJob(requestId, "系统引擎未接受这一段离线合成请求", "TTS_CONTENT") }
                            } catch (_: Exception) { main.post { finishJob(requestId, "离线语音合成失败") } }
                        }
                    }
                } catch (_: Exception) { main.post { guarded.error("TTS_SYNTH", "离线语音合成失败，请重试", null) } }
            }
        }
    }
    private fun finishJob(id: String?, error: String?, code: String = "TTS_SYNTH") {
        val current = job ?: return
        if (id != current.id) return
        job = null
        synthTimeout?.let(main::removeCallbacks)
        synthTimeout = null
        if (error != null || !current.file.exists() || current.file.length() < 45) {
            current.file.delete()
            current.result.error(if (error == null) "TTS_CONTENT" else code, error ?: "系统语音没有生成有效音频", null)
        } else current.result.success(current.file.path)
    }
    private fun cancelJob(reason: String) {
        val current = job ?: return
        val tts = session
        speechWorker.execute { runCatching { tts?.stop() } }
        finishJob(current.id, reason, "TTS_CANCELLED")
    }
    private fun shutdownSession() {
        val tts = session ?: return
        speechWorker.execute { runCatching { tts.shutdown() } }
    }
}
