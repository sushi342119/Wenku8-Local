package org.mewx.wenku8_flutter

import android.app.Activity
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.HapticFeedbackConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal object AppHapticPolicy {
    data class Pulse(val scale: Float, val delayMs: Int = 0)

    fun strength(value: String?): String? = when (value) {
        null, "standard" -> "standard"
        "light", "strong" -> value
        else -> null
    }

    /** Scale the transient, never lengthen a buzz or add repeats for strength. */
    fun pulses(cue: String, strength: String): List<Pulse> {
        val scale = if (strength == "light") .5f else 1f
        return when (cue) {
            "success" -> listOf(Pulse(scale * .65f), Pulse(scale, 55))
            "error" -> listOf(Pulse(scale), Pulse(scale * .8f, 65))
            else -> listOf(Pulse(scale))
        }
    }

    fun feedback(cue: String, sdk: Int): Int? = when (cue) {
        // Match Flutter selectionClick used by the 0.4.6 shelf. Recent segment
        // and handle presets vary substantially across OEMs; ordinary discrete
        // interactions share this brief click rather than a soft impact tail.
        "shelfStep", "detent", "selection", "pageTurn", "action" -> HapticFeedbackConstants.CLOCK_TICK
        "longPress" -> HapticFeedbackConstants.LONG_PRESS
        "boundary" -> HapticFeedbackConstants.CONTEXT_CLICK
        "success" -> if (sdk >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
        "warning" -> if (sdk >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.VIRTUAL_KEY
        "error" -> if (sdk >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.VIRTUAL_KEY
        else -> null
    }

    /** Amplitude is the only honest strength distinction on OEMs that expose it. */
    fun amplitude(strength: String): Int = when (strength) {
        "light" -> 70
        "strong" -> 220
        else -> 140
    }

    fun timings(cue: String, strength: String): LongArray =
        pulses(cue, strength).flatMap { listOf(it.delayMs.toLong(), 18L) }.toLongArray()

    fun amplitudes(cue: String, strength: String, adjustable: Boolean): IntArray =
        pulses(cue, "standard").flatMap {
            listOf(0, if (adjustable) (amplitude(strength) * it.scale).toInt().coerceIn(1, 255) else -1)
        }.toIntArray()

    /** One accepted route: never double-play a successful system preset. */
    fun dispatch(adjustable: Boolean, preset: () -> Boolean, waveform: () -> Boolean): Boolean =
        if (adjustable) waveform() else preset() || waveform()
}

/** Adjustable transients and unsupported-preset recovery respect touch settings. */
class AppHapticsPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var vibrator: Vibrator? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "org.mewx.wenku8_flutter/haptics").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "capabilities") {
            val owner = activity
            val motor = owner?.let { motor(it) }
            result.success(mapOf(
                "hasVibrator" to (motor?.hasVibrator() == true),
                "hasAmplitudeControl" to (Build.VERSION.SDK_INT >= 26 && motor?.hasAmplitudeControl() == true),
                "sdk" to Build.VERSION.SDK_INT,
                "hapticFeedbackEnabled" to if (owner?.window?.decorView?.isHapticFeedbackEnabled != true)
                    false else legacyTouchFeedbackEnabled(owner),
            ))
            return
        }
        if (call.method != "play") { result.notImplemented(); return }
        val options = call.arguments as? Map<*, *>
        val cue = (options?.get("cue") ?: call.arguments) as? String ?: ""
        val strength = AppHapticPolicy.strength(options?.get("strength") as? String)
        if (strength == null) { result.error("BAD_STRENGTH", "Unknown haptic strength", null); return }
        val feedback = AppHapticPolicy.feedback(cue, Build.VERSION.SDK_INT)
        if (feedback == null) { result.error("BAD_CUE", "Unknown haptic cue", null); return }
        val owner = activity
        val view = owner?.window?.decorView
        if (owner == null || owner.isFinishing || view == null || !view.hasWindowFocus() ||
            !view.isHapticFeedbackEnabled) {
            result.success(false); return
        }
        try {
            if (legacyTouchFeedbackEnabled(owner) == false) {
                result.success(false); return
            }
            val motor = motor(owner)
            val adjustable = Build.VERSION.SDK_INT >= 26 && motor?.hasAmplitudeControl() == true
            result.success(AppHapticPolicy.dispatch(
                adjustable = adjustable,
                preset = { view.performHapticFeedback(feedback) },
                waveform = {
                    if (motor == null || !motor.hasVibrator()) false
                    else {
                        val timings = AppHapticPolicy.timings(cue, strength)
                        if (Build.VERSION.SDK_INT < 26) {
                            @Suppress("DEPRECATION")
                            motor.vibrate(timings, -1)
                        } else {
                            val effect = VibrationEffect.createWaveform(
                                timings, AppHapticPolicy.amplitudes(cue, strength, adjustable), -1)
                            if (Build.VERSION.SDK_INT >= 33) {
                                // USAGE_TOUCH applies the platform's current feedback setting.
                                motor.vibrate(effect, VibrationAttributes.Builder()
                                    .setUsage(VibrationAttributes.USAGE_TOUCH).build())
                            } else {
                                @Suppress("DEPRECATION")
                                motor.vibrate(effect, AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                            }
                        }
                        true
                    }
                }
            ))
        } catch (_: RuntimeException) {
            // Optional feedback must not interrupt the accepted action or double-play.
            result.success(false)
        }
    }

    private fun motor(owner: Activity): Vibrator? {
        if (vibrator == null) {
            vibrator = if (Build.VERSION.SDK_INT >= 31)
                owner.getSystemService(VibratorManager::class.java)?.defaultVibrator
            else owner.getSystemService(Vibrator::class.java)
        }
        return vibrator
    }

    // This setting was replaced by USAGE_TOUCH in API 33; do not report its
    // obsolete value as the current system state on newer Android versions.
    @Suppress("DEPRECATION")
    private fun legacyTouchFeedbackEnabled(owner: Activity): Boolean? =
        if (Build.VERSION.SDK_INT >= 33) null else Settings.System.getInt(
            owner.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) != 0

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { detachActivity() }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { detachActivity() }
    private fun detachActivity() {
        activity = null
        vibrator = null
    }
}
