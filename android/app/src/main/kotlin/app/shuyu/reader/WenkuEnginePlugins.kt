package app.shuyu.reader

import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/** The repository survives a detached UI while the audio engine remains alive. */
internal fun attachWenkuEnginePlugins(engine: FlutterEngine) {
    if (!engine.plugins.has(ReadingWidgetsPlugin::class.java)) engine.plugins.add(ReadingWidgetsPlugin())
    if (!engine.plugins.has(AppHapticsPlugin::class.java)) engine.plugins.add(AppHapticsPlugin())
    if (!engine.plugins.has(MonetPlugin::class.java)) engine.plugins.add(MonetPlugin())
    if (!engine.plugins.has(WenkuHostPlugin::class.java)) engine.plugins.add(WenkuHostPlugin())
    if (!engine.plugins.has(SystemSpeechPlugin::class.java)) engine.plugins.add(SystemSpeechPlugin())
    if (!engine.plugins.has(AppUpdatePlugin::class.java)) engine.plugins.add(AppUpdatePlugin())
    if (!engine.plugins.has(CloudSourceConfigPlugin::class.java)) engine.plugins.add(CloudSourceConfigPlugin())
    if (!engine.plugins.has(ReaderControlsPlugin::class.java)) engine.plugins.add(ReaderControlsPlugin())
    if (!engine.plugins.has(NetworkStatusPlugin::class.java)) engine.plugins.add(NetworkStatusPlugin())
    if (!engine.plugins.has(FrameRatePlugin::class.java)) engine.plugins.add(FrameRatePlugin())
}

class WenkuHostPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener, PluginRegistry.NewIntentListener {
    private var api: Wenku8Bridge? = null
    private var apiChannel: MethodChannel? = null
    private var toolsChannel: MethodChannel? = null
    private var tools: LocalTools? = null
    private var documents: BookDocuments? = null
    private var bookImports: BookDocumentImportSession<Uri>? = null
    private var bookOpens: BookOpenRequests? = null
    private var documentsChannel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val main = Handler(Looper.getMainLooper())
        val resolver = binding.applicationContext.contentResolver
        bookImports = BookDocumentImportSession(File(binding.applicationContext.noBackupFilesDir, "book-import-staging")) { uri, target, max ->
            copySelectedBookDocument(resolver, uri, target, max)
        }
        bookOpens = BookOpenRequests(binding.applicationContext)
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
        documentsChannel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/book_documents").also {
            it.setMethodCallHandler { call, result ->
                val attached = documents
                if (attached != null) attached.onMethodCall(call, result)
                else result.error("NO_ACTIVITY", "请在文库页面执行文件操作", null)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        bookImports?.close()
        bookImports = null
        bookOpens = null
        apiChannel?.setMethodCallHandler(null)
        toolsChannel?.setMethodCallHandler(null)
        documentsChannel?.setMethodCallHandler(null)
        api?.close()
        api = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        val existing = tools
        if (existing == null) tools = LocalTools(binding.activity)
        else existing.attachActivity(binding.activity)
        documents = BookDocuments(binding.activity, checkNotNull(bookImports), checkNotNull(bookOpens))
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(this)
        onNewIntent(binding.activity.intent)
        documentsChannel?.invokeMethod("bookOpenAvailable", null)
    }
    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        tools?.close()
        tools = null
        documents?.close()
        documents = null
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onNewIntent(intent: Intent): Boolean {
        if (bookOpens?.offer(intent) != true) return false
        activityBinding?.activity?.let { activity ->
            activity.intent = Intent(activity.intent).apply { action = Intent.ACTION_MAIN; data = null; type = null }
        }
        documentsChannel?.invokeMethod("bookOpenAvailable", null)
        return true
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        (tools?.onActivityResult(requestCode, resultCode, data) ?: false) ||
            (documents?.onActivityResult(requestCode, resultCode, data) ?: false)
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean =
        (tools?.onRequestPermissionsResult(requestCode) ?: false) ||
            (documents?.onRequestPermissionsResult(requestCode) ?: false)
}
