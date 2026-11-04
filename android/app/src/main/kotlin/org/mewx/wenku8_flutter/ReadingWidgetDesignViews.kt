package org.mewx.wenku8_flutter

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/** Four content-first native compositions; classic snapshots keep their original views. */
internal object ReadingWidgetDesignViews {
    fun id(json: JSONObject?): String = json?.optString("layoutId")
        ?.takeIf { it in listOf("focus", "week", "calendar", "memory") } ?: "classic"

    fun create(context: Context, content: ReadingWidgetContent, design: String,
               family: Int, width: Int, height: Int): RemoteViews {
        val illustrated = design == "focus" && content.skin == "seasons" && family > 0
        val layout = if (illustrated) {
            if (family == 2) R.layout.reading_widget_design_focus_large else R.layout.reading_widget_design_focus_medium
        } else when (design) {
            "focus" -> R.layout.reading_widget_design_focus
            "week" -> R.layout.reading_widget_design_week
            "calendar" -> R.layout.reading_widget_design_calendar
            else -> R.layout.reading_widget_design_memory
        }
        val views = RemoteViews(context.packageName, layout)
        val skin = ReadingWidgetSkin(content.skin, content.localDay)
        if (illustrated) {
            val month = content.localDay.drop(5).take(2).toIntOrNull() ?: 1
            val art = when (month) {
                in 3..5 -> R.drawable.widget_season_spring
                in 6..8 -> R.drawable.widget_season_summer
                in 9..11 -> R.drawable.widget_season_autumn
                else -> R.drawable.widget_season_winter
            }
            val original = BitmapFactory.decodeResource(context.resources, art)
            if (original != null) {
                val ratio = if (family == 2) width / 126f else 116f / height
                val cw = minOf(original.width, (original.height * ratio).toInt())
                val ch = minOf(original.height, (original.width / ratio).toInt())
                val cropped = Bitmap.createBitmap(original, ((original.width-cw)*.8f).toInt(),
                    ((original.height-ch)*.15f).toInt(), cw, ch)
                views.setImageViewBitmap(R.id.design_art, cropped)
                if (cropped !== original) original.recycle()
            }
        }
        if (content.skin != "original") {
            views.setInt(R.id.design_content, "setBackgroundColor", Color.TRANSPARENT)
            views.setImageViewBitmap(R.id.design_background, skin.background(width, height, context.resources.displayMetrics.density))
            for (id in listOf(R.id.design_heading, R.id.design_detail, R.id.design_footer)) views.setTextColor(id, skin.muted)
            views.setTextColor(R.id.design_value, if (design == "focus") skin.accent else skin.ink)
        }
        fun text(id: Int, value: String?) {
            views.setTextViewText(id, value.orEmpty())
            views.setViewVisibility(id, if (value.isNullOrBlank()) View.GONE else View.VISIBLE)
        }
        text(R.id.design_footer, content.footer)
        when (design) {
            "focus" -> {
                text(R.id.design_heading, content.localDay.takeIf { it.length == 10 }?.let { "${it.takeLast(5).replace('-', '.')} / 阅读" } ?: "今日阅读")
                text(R.id.design_value, content.todaySeconds?.let { ReadingWidgetContent.minutes(it) })
                text(R.id.design_detail, content.todaySeconds?.let { "分钟" })
                text(R.id.design_goal_caption, content.goalCaption)
                views.setViewVisibility(R.id.design_goal_bar, if (content.dailyGoal > 0 && content.todaySeconds != null) View.VISIBLE else View.GONE)
                if (content.dailyGoal > 0 && content.todaySeconds != null) {
                    views.setImageViewBitmap(R.id.design_goal_bar, skin.progress(content.todaySeconds.toFloat() / (content.dailyGoal * 60), width-32, context.resources.displayMetrics.density))
                }
                if (content.skin != "original") views.setTextColor(R.id.design_goal_caption, skin.muted)
                if (content.streak != null && content.streak > 0) text(R.id.design_footer, "连续 ${content.streak} 天")
                views.setTextViewTextSize(R.id.design_value, TypedValue.COMPLEX_UNIT_SP, if (family == 2) { if (illustrated) 64f else 76f } else { if (illustrated) 44f else 48f })
            }
            "week" -> {
                views.setTextViewTextSize(R.id.design_value, TypedValue.COMPLEX_UNIT_SP, if (family == 2) 40f else 26f)
                text(R.id.design_heading, "七日节律 / 7 DAYS")
                text(R.id.design_value, content.weekSeconds?.let { "${ReadingWidgetContent.minutes(it)} 分钟" })
                text(R.id.design_detail, null)
                views.setViewVisibility(R.id.design_chart, if (content.weekSeconds == null) View.GONE else View.VISIBLE)
                if (content.weekSeconds != null) {
                    views.setImageViewBitmap(R.id.design_chart, week(content, skin, context.resources.displayMetrics.density,
                        width - 32, (height - if (family == 2) 147 else 126).coerceAtLeast(20)))
                    views.setContentDescription(R.id.design_chart, content.week.joinToString("，") {
                        "${it.date}：${it.seconds?.let { value -> ReadingWidgetContent.minutes(value) + " 分钟" } ?: "未记录"}"
                    })
                }
            }
            "calendar" -> {
                text(R.id.design_heading, "阅读日历")
                text(R.id.design_value, content.localDay.takeIf { it.length == 10 }?.take(7)?.replace("-", " / "))
                val known = content.heatmap.visibleCells(family).any { it.level != null }
                text(R.id.design_detail, if (known) "近 ${ReadingWidgetHeatmap.weeks(family)} 周" else null)
                views.setViewVisibility(R.id.design_chart, if (known) View.VISIBLE else View.GONE)
                if (known) {
                    views.setImageViewBitmap(R.id.design_chart, ReadingWidgetHeatmapRenderer.render(
                        content.heatmap, family, "shelf", context.resources.displayMetrics.density,
                        (width - 32).toFloat(), (height - 132).coerceAtLeast(20).toFloat(),
                        if (content.skin == "original") null else ReadingWidgetHeatmapRenderer.Palette(skin.background, skin.muted, skin.accent, skin.secondary)))
                    views.setContentDescription(R.id.design_chart, content.heatmap.description(family))
                }
            }
            else -> {
                views.setTextViewTextSize(R.id.design_value, TypedValue.COMPLEX_UNIT_SP, if (family == 0) 18f else 23f)
                text(R.id.design_heading, if (content.hasMoment) "书页留念" else "下一段故事")
                text(R.id.design_value, if (content.hasMoment) content.bookTitle.ifBlank { content.completionTitle } else "从这一页\n开始。")
                text(R.id.design_detail, content.author.takeIf { it.isNotBlank() })
                text(R.id.design_footer, content.completionCaption.substringBefore(" · "))
                val cover = content.coverPath.takeIf { it.isNotBlank() }?.let { ReadingWidgetProvider.decodeCover(it) }
                views.setViewVisibility(R.id.design_cover, if (cover == null) View.GONE else View.VISIBLE)
                if (cover != null) views.setImageViewBitmap(R.id.design_cover, cover)
            }
        }
        return views
    }

    private fun week(content: ReadingWidgetContent, skin: ReadingWidgetSkin, density: Float, width: Int, height: Int): Bitmap {
        val bitmap = Bitmap.createBitmap((width * density).toInt().coerceAtLeast(1),
            (height * density).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.scale(density, density)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val maximum = maxOf(300, content.week.maxOfOrNull { it.seconds ?: 0 } ?: 0)
        val step = width / 7f
        val baseline = height - 17f
        content.week.forEachIndexed { index, day ->
            val x = step * (index + .5f)
            paint.color = Color.parseColor(if (index == 6) "#E2DAFF" else "#837AA7")
            if (content.skin != "original") paint.color = if (index == 6) skin.accent else ReadingWidgetSkin.blend(skin.accent, skin.background, .55f)
            paint.style = if (day.seconds == null) Paint.Style.STROKE else Paint.Style.FILL
            paint.strokeWidth = 1f
            val barHeight = if (day.seconds == null) 3f else maxOf(2f, (baseline - 2) * day.seconds / maximum)
            canvas.drawRoundRect(x - step * .23f, baseline - barHeight, x + step * .23f, baseline, 2f, 2f, paint)
            paint.style = Paint.Style.FILL
            paint.color = Color.parseColor("#A5B0CD")
            if (content.skin != "original") paint.color = skin.muted
            paint.textAlign = Paint.Align.CENTER
            paint.textSize = 9f
            canvas.drawText(day.date.takeLast(2), x, height - 2f, paint)
        }
        return bitmap
    }
}
