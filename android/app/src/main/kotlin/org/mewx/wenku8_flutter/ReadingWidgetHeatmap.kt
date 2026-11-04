package org.mewx.wenku8_flutter

import org.json.JSONObject
import java.time.LocalDate

/** A Monday-aligned, snapshot-dated calendar. Null is never inferred as zero. */
internal class ReadingWidgetHeatmap(json: JSONObject?) {
    data class Cell(val date: LocalDate?, val seconds: Int?, val today: Boolean, val future: Boolean) {
        val level: Int? get() = when {
            seconds == null -> null
            seconds == 0 -> 0
            seconds < 900 -> 1
            seconds < 1800 -> 2
            seconds < 3600 -> 3
            else -> 4
        }
    }

    val localDay = date(json?.optString("localDay"))
    val startDate = localDay?.minusDays((localDay.dayOfWeek.value - 1).toLong())?.minusWeeks(25)
    private val block = json?.optJSONObject("heatmap")
    private val supplied = block?.optJSONArray("verifiedSeconds")
    val usesCalendarBlock = startDate != null && block != null &&
        block.opt("weekStart") == 1 && date(block.optString("startDate")) == startDate &&
        supplied?.length() == 182 && (0 until 182).all { index ->
            supplied.isNull(index) || seconds(supplied.opt(index)) != null
        }
    private val fallback = buildMap<LocalDate, Int?> {
        val week = json?.optJSONArray("week")
        for (index in 0 until minOf(7, week?.length() ?: 0)) {
            val day = week?.optJSONObject(index) ?: continue
            val calendarDate = date(day.optString("date")) ?: continue
            put(calendarDate, seconds(day.opt("verifiedSeconds")))
        }
    }
    val cells = (0 until 182).map { index ->
        val day = startDate?.plusDays(index.toLong())
        val future = day != null && localDay != null && day > localDay
        val value = if (day == null || future) null else if (usesCalendarBlock) {
            seconds(supplied?.opt(index))
        } else fallback[day]
        Cell(day, value, day != null && day == localDay, future)
    }

    fun visibleCells(family: Int): List<Cell> = cells.takeLast(weeks(family) * 7)
    fun description(family: Int): String {
        val known = visibleCells(family).filter { !it.future && it.seconds != null }
        return "近${weeks(family)}周阅读热力图，周一至周日；${known.count { it.seconds!! > 0 }}天有有效阅读，" +
            "${known.count { it.seconds == 0 }}天已记录为零；空心为未记录，深色表示阅读更久。" +
            (localDay?.let { "截至$it。" } ?: "尚无阅读记录。")
    }

    companion object {
        fun weeks(family: Int): Int = when (family) { 0 -> 7; 1 -> 13; else -> 26 }
        fun date(value: String?): LocalDate? = if (value == null || !Regex("\\d{4}-\\d{2}-\\d{2}").matches(value)) null
            else runCatching { LocalDate.parse(value) }.getOrNull()
        private fun seconds(value: Any?): Int? = when (value) {
            is Int -> value.takeIf { it >= 0 }
            is Long -> value.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.toInt()
            else -> null
        }
    }
}
