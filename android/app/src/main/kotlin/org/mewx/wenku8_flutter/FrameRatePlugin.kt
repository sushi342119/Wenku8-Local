package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Display
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Settings and status only. HighRefreshRateController remains the sole voter. */
class FrameRatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, DisplayManager.DisplayListener {
    private var activity: Activity? = null
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val manager get() = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/frame_rate")
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) { detach(); channel.setMethodCallHandler(null) }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        manager.registerDisplayListener(this, Handler(Looper.getMainLooper()))
    }
    private fun detach() { manager.unregisterDisplayListener(this); activity = null }
    override fun onDetachedFromActivityForConfigChanges() = detach()
    override fun onDetachedFromActivity() = detach()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    @Suppress("DEPRECATION")
    private fun display(): Display = activity?.let { if (Build.VERSION.SDK_INT >= 30) it.display else it.windowManager.defaultDisplay } ?: error("请在文库页面调整帧率")
    private fun mode(value: Display.Mode) = RefreshRatePolicy.Mode(value.modeId, value.physicalWidth, value.physicalHeight, value.refreshRate)
    private fun info(): Map<String, Any?> {
        val display = display()
        val current = mode(display.mode)
        val modes = display.supportedModes.map(::mode)
        val target = context.getSharedPreferences("frame_rate_settings", 0).getFloat("target", 0f)
        val selected = RefreshRatePolicy.select(Build.VERSION.SDK_INT, current, modes, target)
        val window = activity?.window ?: error("请在文库页面调整帧率")
        val attrs = window.attributes
        val requested = modes.firstOrNull { it.id == attrs.preferredDisplayModeId }?.rate
            ?: attrs.preferredRefreshRate
        val status = (activity as? MainActivity)?.frameRateStatus()
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        // Intent, submitted votes, and the display mode reported to this app are
        // different facts. OEM overrides may also differ from the physical mode.
        return mapOf("target" to target.toDouble(),
            "current" to display.refreshRate.toDouble(),
            "currentModeId" to current.id,
            "currentModeRate" to current.rate.toDouble(),
            "selectedModeId" to (selected?.modeId ?: 0),
            "selectedRate" to (selected?.rate ?: 0f).toDouble(),
            "requestStatusAvailable" to (status != null),
            "requestedModeId" to attrs.preferredDisplayModeId,
            "requestedRate" to requested.toDouble(),
            "controllerActive" to status?.active,
            "windowFocused" to window.decorView.hasWindowFocus(),
            "surfaceCount" to status?.surfaceCount,
            "submittedSurfaceCount" to status?.submittedSurfaceCount,
            "surfaceRequestedRate" to status?.surfaceRate?.toDouble(),
            "surfaceRequestState" to status?.surfaceState,
            "surfaceRequestError" to status?.surfaceError,
            "viewRequestedRate" to status?.viewRate?.toDouble(),
            "powerSaveMode" to power.isPowerSaveMode,
            "thermalStatus" to if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else null,
            "rates" to RefreshRatePolicy.rates(current, modes).map { it.toDouble() })
    }
    internal fun onRequestChanged() { if (activity != null) channel.invokeMethod("changed", null) }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "info" -> result.success(info())
                "set" -> {
                    val rate = call.argument<Number>("target")?.toFloat() ?: error("请选择帧率")
                    val display = display()
                    val supported = RefreshRatePolicy.rates(mode(display.mode), display.supportedModes.map(::mode))
                    require(rate == 0f || rate == -1f || rate.isFinite() && supported.any { kotlin.math.abs(it - rate) < .5f }) { "当前屏幕不支持此刷新率，请重新选择" }
                    check(context.getSharedPreferences("frame_rate_settings", 0).edit().putFloat("target", rate).commit()) { "帧率设置未保存，请重试" }
                    result.success(info())
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("frame_rate", error.message ?: "刷新率信息读取失败", null) }
    }
    override fun onDisplayAdded(displayId: Int) { channel.invokeMethod("changed", null) }
    override fun onDisplayRemoved(displayId: Int) { channel.invokeMethod("changed", null) }
    override fun onDisplayChanged(displayId: Int) { if (activity != null && runCatching { display().displayId }.getOrNull() == displayId) channel.invokeMethod("changed", null) }
}
