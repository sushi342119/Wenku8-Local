package org.mewx.wenku8_flutter

import android.graphics.*

/** Native vector decorations: no extra full-resolution illustration bundle. */
internal class ReadingWidgetSkin(val id: String, date: String) {
    private val month = date.drop(5).take(2).toIntOrNull() ?: 1
    private val season = when (month) { in 3..5 -> 0; in 6..8 -> 1; in 9..11 -> 2; else -> 3 }
    private val seasons = listOf("#AF7D8B", "#5786A2", "#B18842", "#4F8985")
    val background = Color.parseColor(when (id) { "night" -> "#101419"; "film" -> "#10100F"; "paper" -> "#ECECE5"; else -> "#F4F0E6" })
    val ink = Color.parseColor(if (id == "night" || id == "film") "#F6F1E6" else "#272C29")
    val accent = Color.parseColor(when (id) { "seasons" -> seasons[season]; "night", "film" -> "#DCB65E"; "paper" -> "#606D5D"; else -> "#4F8985" })
    val muted: Int get() = blend(ink, background, .65f)
    val secondary: Int get() = blend(ink, background, .12f)
    fun background(width: Int, height: Int, density: Float): Bitmap {
        val bitmap = Bitmap.createBitmap((width * density).toInt().coerceAtLeast(1), (height * density).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); canvas.scale(density, density)
        val w = width.toFloat(); val h = height.toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG); paint.color = background
        canvas.drawRoundRect(0f, 0f, w, h, 22f, 22f, paint)
        canvas.clipPath(Path().apply { addRoundRect(0f, 0f, w, h, 22f, 22f, Path.Direction.CW) })
        paint.color = accent
        when (id) {
            "seasons" -> {
                seasons.forEachIndexed { i, color -> paint.color = Color.parseColor(color); canvas.drawRect(i*w/4, h-5, (i+1)*w/4, h, paint) }
                paint.color = blend(accent, background, .13f); paint.textSize = 62f; paint.textAlign = Paint.Align.RIGHT
                paint.typeface = Typeface.create("serif", Typeface.BOLD)
                canvas.drawText(listOf("春", "夏", "秋", "冬")[season], w-12, 65f, paint)
            }
            "archive" -> {
                canvas.drawRect(0f, 0f, 4f, h, paint)
                for (x in width-44..width-13 step 3) canvas.drawRect(x.toFloat(), h-26, x+1f, h-14, paint)
            }
            "night" -> {
                canvas.drawCircle(w-25, 25f, 8f, paint); paint.color = background; canvas.drawCircle(w-21, 21f, 8f, paint)
                paint.color = blend(ink, background, .06f)
                for (i in 0..7) canvas.drawRect(i*w/8, h-10-(i%3)*6, i*w/8+w/10, h, paint)
            }
            "film" -> {
                paint.color = Color.parseColor("#D6D2C7")
                for (x in 12..width-8 step 14) { canvas.drawRect(x.toFloat(),3f,x+6f,7f,paint); canvas.drawRect(x.toFloat(),h-7,x+6f,h-3,paint) }
            }
            "paper" -> {
                paint.color = blend(accent, background, .3f); canvas.save(); canvas.rotate(7f, w-27, 4f)
                canvas.drawRect(w-37,-2f,w-13,11f,paint); canvas.restore()
            }
        }
        return bitmap
    }
    fun progress(ratio: Float, width: Int, density: Float): Bitmap {
        val bitmap = Bitmap.createBitmap((width*density).toInt().coerceAtLeast(1), (4*density).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val h = bitmap.height.toFloat(); val w = bitmap.width.toFloat()
        paint.color = secondary; canvas.drawRoundRect(0f,0f,w,h,h/2,h/2,paint)
        paint.color = accent; canvas.drawRoundRect(0f,0f,w*ratio.coerceIn(0f,1f),h,h/2,h/2,paint)
        return bitmap
    }
    companion object {
        fun blend(a: Int, b: Int, weight: Float): Int = Color.rgb(
            (Color.red(a)*weight+Color.red(b)*(1-weight)).toInt(),
            (Color.green(a)*weight+Color.green(b)*(1-weight)).toInt(),
            (Color.blue(a)*weight+Color.blue(b)*(1-weight)).toInt())
    }
}
