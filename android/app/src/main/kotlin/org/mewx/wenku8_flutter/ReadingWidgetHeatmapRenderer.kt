package org.mewx.wenku8_flutter

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import kotlin.math.min

/** Only the data chart is rasterized; the widget remains native live RemoteViews. */
internal object ReadingWidgetHeatmapRenderer {
    data class Palette(val background: Int, val muted: Int, val accent: Int, val secondary: Int)
    fun palette(theme: String): Palette {
        val values = when (theme) {
            "shelf" -> listOf("EEF4F0", "5C6C63", "3E7361", "BED3C7")
            "editorial" -> listOf("FAF6E9", "6F6854", "9B8141", "DAD0AD")
            "constellation" -> listOf("101629", "A5B0CD", "B4A3F5", "334267")
            "signal" -> listOf("F0F1E8", "5F6F69", "4F7E6C", "C8D098")
            "score" -> listOf("FFF4F3", "786275", "C84D76", "F0BACD")
            "ink" -> listOf("F6F4E9", "607167", "A4473A", "B8D1C7")
            "festival" -> listOf("F2F8FB", "566F7D", "E47843", "AECEDF")
            else -> listOf("F7F8F6", "66727B", "2E769E", "C8D9E0")
        }.map { Color.parseColor("#$it") }
        return Palette(values[0], values[1], values[2], values[3])
    }

    fun render(calendar: ReadingWidgetHeatmap, family: Int, theme: String, density: Float,
               width: Float = if (family == 0) 150f else 330f,
               height: Float = when (family) { 0 -> 68f; 1 -> 70f; else -> 49f }, skinPalette: Palette? = null): Bitmap {
        val weeks = ReadingWidgetHeatmap.weeks(family)
        val bitmap = Bitmap.createBitmap((width * density).toInt().coerceAtLeast(1),
            (height * density).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.scale(density, density)
        val palette = skinPalette ?: palette(theme)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val labelWidth = 15f
        val stepX = (width - labelWidth) / weeks
        val stepY = height / 7f
        val radius = min(2.7f, min(stepX, stepY) * .30f)
        paint.textSize = 8f
        paint.color = palette.muted
        for ((row, label) in listOf(0 to "一", 2 to "三", 4 to "五", 6 to "日")) {
            canvas.drawText(label, 0f, stepY * (row + .5f) - (paint.ascent() + paint.descent()) / 2f, paint)
        }
        calendar.visibleCells(family).forEachIndexed { index, cell ->
            if (cell.future) return@forEachIndexed
            val x = labelWidth + stepX * (index / 7 + .5f)
            val y = stepY * (index % 7 + .5f)
            paint.strokeWidth = .7f
            paint.style = if (cell.level == null) Paint.Style.STROKE else Paint.Style.FILL
            paint.color = when (cell.level) {
                null -> blend(palette.background, palette.muted, .45f)
                0 -> blend(palette.background, palette.secondary, .62f)
                1 -> blend(palette.background, palette.accent, .28f)
                2 -> blend(palette.background, palette.accent, .51f)
                3 -> blend(palette.background, palette.accent, .74f)
                else -> palette.accent
            }
            canvas.drawCircle(x, y, radius, paint)
            if (cell.today) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = .8f
                paint.color = palette.accent
                canvas.drawCircle(x, y, min(radius + 1.3f, min(stepX, stepY) / 2f - .5f), paint)
            }
        }
        return bitmap
    }

    private fun blend(from: Int, to: Int, ratio: Float): Int = Color.rgb(
        (Color.red(from) + (Color.red(to) - Color.red(from)) * ratio).toInt(),
        (Color.green(from) + (Color.green(to) - Color.green(from)) * ratio).toInt(),
        (Color.blue(from) + (Color.blue(to) - Color.blue(from)) * ratio).toInt())
}
