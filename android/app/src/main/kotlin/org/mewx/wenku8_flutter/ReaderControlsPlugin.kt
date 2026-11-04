package org.mewx.wenku8_flutter

import android.app.Activity
import android.view.KeyEvent
import android.view.View
import android.provider.Settings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class ReaderControlsPlugin : FlutterPlugin, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var volumePaging = false
    private var lastPage = 0L
    private var statusEvents: EventChannel? = null
    private var statusReceiver: BroadcastReceiver? = null
    private var applicationContext: Context? = null
    private fun stopStatusEvents() {
        statusReceiver?.let { applicationContext?.unregisterReceiver(it) }
        statusReceiver = null
    }
    private fun status(context: Context): Map<String, Any?> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val state = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return mapOf("time" to System.currentTimeMillis(), "battery" to if (level >= 0 && scale > 0) level * 100 / scale else null,
            "charging" to (state == BatteryManager.BATTERY_STATUS_CHARGING || state == BatteryManager.BATTERY_STATUS_FULL))
    }
    private fun hideStatusBar(hidden: Boolean) {
        activity?.window?.let { window ->
            ReaderWindowLayout.apply(window)
            val controller = WindowCompat.getInsetsController(window, window.decorView)
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            if (hidden) controller.hide(WindowInsetsCompat.Type.statusBars())
            else controller.show(WindowInsetsCompat.Type.statusBars())
        }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        statusEvents = EventChannel(binding.binaryMessenger, "org.mewx.wenku8/reader_status").also { events ->
            events.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    stopStatusEvents()
                    val context = binding.applicationContext
                    statusReceiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent?) { sink.success(status(context)) }
                    }.also { receiver ->
                        ContextCompat.registerReceiver(context, receiver, IntentFilter().apply {
                            addAction(Intent.ACTION_BATTERY_CHANGED); addAction(Intent.ACTION_TIME_TICK)
                            addAction(Intent.ACTION_TIME_CHANGED); addAction(Intent.ACTION_TIMEZONE_CHANGED)
                        }, ContextCompat.RECEIVER_NOT_EXPORTED)
                    }
                    sink.success(status(context))
                }
                override fun onCancel(arguments: Any?) = stopStatusEvents()
            })
        }
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/reader_controls").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "navigationCapabilities") {
                    result.success(mapOf("systemFloatingNavigation" to android.os.Build.MANUFACTURER.equals("HUAWEI", true)))
                    return@setMethodCallHandler
                }
                if (call.method == "navigationSettings") {
                    try {
                        val context = activity ?: applicationContext ?: error("No context")
                        context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    } catch (_: Exception) { result.error("SETTINGS", "请在手机设置中搜索悬浮导航", null) }
                    return@setMethodCallHandler
                }
                if (call.method == "windowInsets") {
                    val view = activity?.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
                    result.success(view?.let(CaptionBarInsets::read))
                    return@setMethodCallHandler
                }
                if (call.method == "brightness") {
                    val current = activity
                    if (current == null) { result.error("NO_ACTIVITY", "阅读页面未显示", null); return@setMethodCallHandler }
                    val windowValue = current.window.attributes.screenBrightness
                    val value = if (windowValue >= 0f) windowValue else
                        Settings.System.getInt(current.contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255f
                    result.success(value.coerceIn(0f, 1f).toDouble()); return@setMethodCallHandler
                }
                if (call.method != "apply") { result.notImplemented(); return@setMethodCallHandler }
                volumePaging = call.argument<Boolean>("volumePaging") == true
                val brightness = call.argument<Number>("brightness")?.toFloat() ?: -1f
                if (brightness != -1f && brightness !in 0f..1f) {
                    result.error("brightness", "阅读亮度超出范围", null); return@setMethodCallHandler
                }
                activity?.window?.let { window -> val attrs = window.attributes; attrs.screenBrightness = brightness; window.attributes = attrs }
                hideStatusBar(call.argument<Boolean>("hideStatusBar") == true)
                result.success(null)
            }
        }
    }
    fun dispatch(event: KeyEvent): Boolean {
        if (!volumePaging || activity?.hasWindowFocus() != true ||
            event.keyCode !in setOf(KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN)) return false
        if (event.action == KeyEvent.ACTION_DOWN && (event.repeatCount == 0 || event.eventTime - lastPage >= 160)) {
            lastPage = event.eventTime
            channel?.invokeMethod("page", if (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP) -1 else 1)
        }
        return true
    }
    fun suspend() {
        volumePaging = false
        hideStatusBar(false)
        activity?.window?.let { window -> val attrs = window.attributes; attrs.screenBrightness = -1f; window.attributes = attrs }
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { suspend(); activity = null }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { suspend(); stopStatusEvents(); statusEvents?.setStreamHandler(null); statusEvents = null; applicationContext = null; channel?.setMethodCallHandler(null); channel = null }
}
