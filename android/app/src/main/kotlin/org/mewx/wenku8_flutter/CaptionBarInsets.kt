package org.mewx.wenku8_flutter

import android.os.Build
import android.view.View
import android.view.WindowInsets

/** Flutter grows the top inset to every caption rectangle's bottom on API 35.
 * Some window managers also include the bottom window handle in that list.
 * Keep actual top controls; do not treat the bottom handle as a giant title bar.
 * See flutter/flutter#161086. No fixed device/brand or status-bar-height cap. */
internal object CaptionBarInsets {
    data class Bounds(val top: Int, val bottom: Int)

    fun correctedTop(height: Int, baseTop: Int, rectangles: List<Bounds>): Int? {
        if (height <= 0 || rectangles.isEmpty()) return null
        val top = rectangles.filter { it.top <= 0 && it.bottom in 1 until height }
            .maxOfOrNull { it.bottom } ?: 0
        val expected = maxOf(baseTop, top)
        val engineTop = maxOf(baseTop, rectangles.maxOf { it.bottom })
        return expected.takeIf { engineTop > expected }
    }

    fun read(view: View): Map<String, Int>? {
        if (Build.VERSION.SDK_INT < 35 || view.width <= 0 || view.height <= 0) return null
        val insets = view.rootWindowInsets ?: return null
        val bars = insets.getInsets(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
        val cutout = insets.displayCutout
        val baseTop = maxOf(bars.top, cutout?.safeInsetTop ?: 0, cutout?.waterfallInsets?.top ?: 0)
        val top = correctedTop(view.height, baseTop,
            insets.getBoundingRects(WindowInsets.Type.captionBar()).map { Bounds(it.top, it.bottom) }
        ) ?: return null
        return mapOf("width" to view.width, "height" to view.height, "top" to top)
    }
}
