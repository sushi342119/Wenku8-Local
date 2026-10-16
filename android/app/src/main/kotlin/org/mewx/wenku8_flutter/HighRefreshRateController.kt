package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import io.flutter.embedding.android.FlutterImageView
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView

/** Keeps the preference attached to the live Flutter rendering surface. */
internal class HighRefreshRateController(private val activity: Activity) :
    DisplayManager.DisplayListener, ViewTreeObserver.OnGlobalLayoutListener {
    private val manager = activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val handler = Handler(Looper.getMainLooper())
    private val root get() = activity.window.decorView
    private val surfaces = LinkedHashMap<SurfaceView, SurfaceBinding>()
    private val viewRates = LinkedHashMap<View, Float>()
    private var preference: RefreshRatePolicy.Preference? = null
    private var active = false
    private val reconcile = Runnable { if (active) update() }

    fun start() {
        if (active) return
        active = true
        manager.registerDisplayListener(this, handler)
        root.viewTreeObserver.addOnGlobalLayoutListener(this)
        update()
        // The shared audio engine may attach its FlutterView after onResume.
        root.post(reconcile)
    }

    fun refresh() {
        if (active) { root.removeCallbacks(reconcile); root.post(reconcile) }
    }

    fun stop() {
        if (!active) return
        active = false
        root.removeCallbacks(reconcile)
        manager.unregisterDisplayListener(this)
        if (root.viewTreeObserver.isAlive) root.viewTreeObserver.removeOnGlobalLayoutListener(this)
        surfaces.values.forEach { it.close() }
        surfaces.clear()
        if (Build.VERSION.SDK_INT >= 36) {
            viewRates.forEach { (view, previous) -> view.requestedFrameRate = previous }
        }
        viewRates.clear()
        preference = null
    }

    @Suppress("DEPRECATION")
    private fun currentDisplay(): Display? =
        if (Build.VERSION.SDK_INT >= 30) activity.display else activity.windowManager.defaultDisplay

    private fun update() {
        val display = currentDisplay() ?: return
        val current = display.mode
        val selected = RefreshRatePolicy.select(Build.VERSION.SDK_INT,
            RefreshRatePolicy.Mode(current.modeId, current.physicalWidth, current.physicalHeight, current.refreshRate),
            display.supportedModes.map {
                RefreshRatePolicy.Mode(it.modeId, it.physicalWidth, it.physicalHeight, it.refreshRate)
            }) ?: return
        preference = selected
        val attrs = activity.window.attributes
        if (attrs.preferredDisplayModeId != selected.modeId || attrs.preferredRefreshRate != selected.rate) {
            attrs.preferredDisplayModeId = selected.modeId
            attrs.preferredRefreshRate = selected.rate
            activity.window.attributes = attrs
        }
        bindRenderingViews(selected.rate)
    }

    private fun bindRenderingViews(rate: Float) {
        val liveSurfaces = HashSet<SurfaceView>()
        val liveViews = HashSet<View>()
        fun visit(view: View) {
            val flutterRenderer = view is FlutterView || view is FlutterSurfaceView ||
                view is FlutterTextureView || view is FlutterImageView
            if (flutterRenderer && view.isAttachedToWindow) {
                liveViews.add(view)
                // ViewGroup votes are not inherited. Vendor-defined HIGH can
                // mean only 90 Hz on a 120 Hz device, so use the actual number.
                if (Build.VERSION.SDK_INT >= 36) {
                    if (!viewRates.containsKey(view)) viewRates[view] = view.requestedFrameRate
                    if (view.requestedFrameRate != rate) view.requestedFrameRate = rate
                }
                if (view is SurfaceView) {
                    liveSurfaces.add(view)
                    surfaces.getOrPut(view) { SurfaceBinding(view) }.applyRate(rate)
                }
            }
            if (view is ViewGroup) for (i in 0 until view.childCount) visit(view.getChildAt(i))
        }
        visit(root)
        surfaces.keys.filter { it !in liveSurfaces }.forEach { surfaces.remove(it)?.close() }
        viewRates.keys.filter { it !in liveViews }.forEach { view ->
            val previous = viewRates.remove(view)!!
            if (Build.VERSION.SDK_INT >= 36) view.requestedFrameRate = previous
        }
    }

    private inner class SurfaceBinding(private val view: SurfaceView) : SurfaceHolder.Callback {
        private val vote = SurfaceRateVote()
        private var rate = 0f
        init { view.holder.addCallback(this) }
        fun applyRate(value: Float) {
            rate = value
            val surface = view.holder.surface
            if (Build.VERSION.SDK_INT < 30) return
            try {
                vote.apply(value, surface.isValid) {
                    if (Build.VERSION.SDK_INT >= 31) surface.setFrameRate(it,
                        Surface.FRAME_RATE_COMPATIBILITY_DEFAULT, Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)
                    else surface.setFrameRate(it, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                }
            } catch (_: IllegalStateException) {
                // Destruction can race hierarchy events. Retry on the next real
                // lifecycle event, never in a per-frame or timer polling loop.
                vote.invalidate()
            }
        }
        override fun surfaceCreated(holder: SurfaceHolder) { vote.invalidate(); applyRate(rate) }
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = applyRate(rate)
        override fun surfaceDestroyed(holder: SurfaceHolder) = vote.invalidate()
        fun close() { view.holder.removeCallback(this); applyRate(0f) }
    }

    override fun onGlobalLayout() { if (active) preference?.let { bindRenderingViews(it.rate) } }
    override fun onDisplayAdded(displayId: Int) = refresh()
    override fun onDisplayRemoved(displayId: Int) = refresh()
    override fun onDisplayChanged(displayId: Int) {
        if (currentDisplay()?.displayId == displayId) refresh()
    }
}
