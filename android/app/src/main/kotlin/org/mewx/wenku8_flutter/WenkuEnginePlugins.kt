package org.mewx.wenku8_flutter

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** The repository survives a detached UI while the audio engine remains alive. */
internal fun attachWenkuEnginePlugins(engine: FlutterEngine) {
    if (!engine.plugins.has(WenkuHostPlugin::class.java)) engine.plugins.add(WenkuHostPlugin())
    if (!engine.plugins.has(SystemSpeechPlugin::class.java)) engine.plugins.add(SystemSpeechPlugin())
    if (!engine.plugins.has(AppUpdatePlugin::class.java)) engine.plugins.add(AppUpdatePlugin())
}

class WenkuHostPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private var api: Wenku8Bridge? = null
    private var apiChannel: MethodChannel? = null
    private var toolsChannel: MethodChannel? = null
    private var tools: LocalTools? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val main = Handler(Looper.getMainLooper())
        api = Wenku8Bridge(binding.applicationContext) { main.post(it) }
        apiChannel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/legacy_api").also {
            it.setMethodCallHandler(api)
        }
        toolsChannel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/local_tools").also {
            it.setMethodCallHandler { call, result ->
                val attached = tools
                if (attached != null) attached.onMethodCall(call, result)
                else result.error("NO_ACTIVITY", "This action needs the app page", null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        apiChannel?.setMethodCallHandler(null)
        toolsChannel?.setMethodCallHandler(null)
        api?.close()
        api = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        tools = LocalTools(binding.activity)
        binding.addActivityResultListener(this)
    }
    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        tools?.close()
        tools = null
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        tools?.onActivityResult(requestCode, resultCode, data) ?: false
}
