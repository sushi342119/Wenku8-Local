package org.mewx.wenku8_flutter

import android.os.Build
import android.view.Window
import android.view.WindowManager
import androidx.core.view.WindowCompat

/** Preserve Flutter's edge-to-edge surface when the status bar is hidden. */
internal object ReaderWindowLayout {
    fun cutoutMode(sdk: Int): Int? = when {
        sdk >= 30 -> WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        sdk >= 28 -> WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        else -> null
    }

    fun apply(window: Window) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        if (Build.VERSION.SDK_INT >= 28) {
            val attributes = window.attributes
            val mode = cutoutMode(Build.VERSION.SDK_INT)!!
            if (attributes.layoutInDisplayCutoutMode != mode) {
                attributes.layoutInDisplayCutoutMode = mode
                window.attributes = attributes
            }
        }
        if (Build.VERSION.SDK_INT >= 29) window.isStatusBarContrastEnforced = false
    }
}
