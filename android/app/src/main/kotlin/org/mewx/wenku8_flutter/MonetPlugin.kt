package org.mewx.wenku8_flutter

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Public system colors only. Never reads wallpaper images or storage. */
class MonetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8/palette").also { it.setMethodCallHandler(this) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> result.success(readMonetInfo(context))
                "icon" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: error("图标设置无效")
                    setMonetIcon(context, enabled)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) { result.error("palette", "配色或图标设置未完成，请重试", null) }
    }
}

internal fun monetAliases(context: Context) = listOf("LauncherOriginal", "LauncherMonet").map {
    ComponentName(context.packageName, "${context.packageName}.$it")
}

internal fun monetIconsSupported(context: Context): Boolean {
    // Debug/profile keep Flutter's direct launcher for normal run/drive tooling.
    if (Build.VERSION.SDK_INT < 33 || context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) return false
    return try {
        monetAliases(context).all {
            @Suppress("DEPRECATION") val info = context.packageManager.getActivityInfo(it, PackageManager.MATCH_DISABLED_COMPONENTS)
            info.targetActivity == "org.mewx.wenku8_flutter.MainActivity"
        }
    } catch (_: PackageManager.NameNotFoundException) { false }
}

internal fun readMonetInfo(context: Context): Map<String, Any?> {
    val resources = context.resources
    val suffixes = listOf(1000, 900, 800, 700, 600, 500, 400, 300, 200, 100, 50, 10, 0)
    val palettes = if (Build.VERSION.SDK_INT >= 31) listOf("accent1", "accent2", "accent3", "neutral1", "neutral2").map { name ->
        suffixes.map { suffix ->
            val id = resources.getIdentifier("system_${name}_$suffix", "color", "android")
            check(id != 0) { "System tonal resource missing" }
            resources.getColor(id, context.theme).toLong() and 0xffffffffL
        }
    } else null
    val supported = monetIconsSupported(context)
    val enabled = !supported || readMonetIcon(context)
    return mapOf("palettes" to palettes, "iconSupported" to supported, "themedIcon" to enabled)
}

/** Resolves DEFAULT against the manifest instead of treating it as enabled. */
private fun monetAliasEnabled(context: Context, alias: ComponentName): Boolean =
    when (context.packageManager.getComponentEnabledSetting(alias)) {
        PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> {
            @Suppress("DEPRECATION")
            context.packageManager.getActivityInfo(alias, PackageManager.MATCH_DISABLED_COMPONENTS).enabled
        }
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
        else -> false
    }

internal fun readMonetIcon(context: Context): Boolean {
    val enabled = monetAliases(context).map { monetAliasEnabled(context, it) }
    check(enabled.count { it } == 1) { "Exactly one icon launcher must be enabled" }
    return enabled[1]
}

internal fun setMonetIcon(context: Context, enabled: Boolean) {
    check(monetIconsSupported(context)) { "Themed icon is unavailable" }
    if (Build.VERSION.SDK_INT >= 33) {
        val aliases = monetAliases(context)
        if (readMonetIcon(context) == enabled) return
        val before = aliases.map { context.packageManager.getComponentEnabledSetting(it) }
        try {
            // The aliases own only an already-finished compatibility launcher.
            // ReaderActivity and permanent file/recovery entries stay enabled.
            context.packageManager.setComponentEnabledSettings(listOf(
                PackageManager.ComponentEnabledSetting(aliases[0], if (enabled) PackageManager.COMPONENT_ENABLED_STATE_DISABLED else PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP),
                PackageManager.ComponentEnabledSetting(aliases[1], if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP),
            ))
            check(readMonetIcon(context) == enabled) { "Icon state was not applied" }
        } catch (failure: Exception) {
            try {
                context.packageManager.setComponentEnabledSettings(aliases.mapIndexed { index, alias ->
                    PackageManager.ComponentEnabledSetting(alias, before[index], PackageManager.DONT_KILL_APP)
                })
            } catch (rollback: Exception) {
                failure.addSuppressed(rollback)
            }
            throw failure
        }
    }
}
