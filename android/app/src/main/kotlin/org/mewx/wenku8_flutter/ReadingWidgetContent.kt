package org.mewx.wenku8_flutter

import org.json.JSONObject

/** Text and real series used by native RemoteViews. No artwork encodes data. */
internal class ReadingWidgetContent(json: JSONObject?) {
    data class Day(val date: String, val seconds: Int?)

    val streak = number(json, "qualifiedStreakDays")
    val streakText = streak?.toString() ?: "—"
    val todaySeconds = number(json, "verifiedTodaySeconds")
    val localDay = json?.optString("localDay").orEmpty()
    val skin = json?.optString("skinId")?.takeIf { it in listOf("seasons", "archive", "night", "film", "paper") } ?: "original"
    val dailyGoal = (json?.opt("dailyGoalMinutes") as? Number)?.toDouble()
        ?.takeIf { it.isFinite() && it >= 1 && it <= 1440 && it % 1.0 == 0.0 }?.toInt() ?: 0
    val goalCaption: String get() = if (dailyGoal == 0) "" else if (todaySeconds == null) "每日目标 $dailyGoal 分钟"
        else if (todaySeconds >= dailyGoal * 60) "今日目标已达成"
        else "目标 $dailyGoal 分 · 还差 ${(dailyGoal * 60 - todaySeconds + 59) / 60} 分"
    val heatmap = ReadingWidgetHeatmap(json)
    val week = (0..6).map { index ->
        val day = json?.optJSONArray("week")?.optJSONObject(index)
        Day(day?.optString("date").orEmpty(), number(day, "verifiedSeconds"))
    }
    val weekSeconds = if (week.all { it.seconds == null }) null else week.sumOf { it.seconds ?: 0 }
    val weekMinutes = minutes(weekSeconds)
    val footer = if (localDay.length == 10) "截至 ${localDay.substring(5).replace('-', '.')}" else "从这一页开始"
    val smallDetail = "${if (localDay.length == 10) localDay.substring(5).replace('-', '.') else "有效阅读"} · ${minutes(todaySeconds)} 分钟"
    val weekDetail = "近7日 $weekMinutes 分钟"
    private val completion = json?.optJSONObject("latestCompletion")
    val hasMoment = completion != null
    val finished = completion?.optBoolean("finished", true) != false
    private val showBookDetails = json?.optBoolean("showBookDetails") == true
    private fun privateText(key: String): String =
        if (showBookDetails && completion != null && !completion.isNull(key)) completion.optString(key) else ""
    val bookTitle = privateText("title")
    val author = privateText("author")
    val coverPath = privateText("coverPath")
    val completionTitle = if (completion == null) "下一页，\n从此开始。"
        else if (finished) "每一页，\n都算数。" else "故事未完，\n阅读继续。"
    val completionDetail = bookTitle.ifBlank {
        if (completion == null) "每一段故事，都从一页开始。" else "把时间留给书页。"
    }
    val completionCaption = if (completion == null) footer else {
        val completed = completion.optString("completedAt").take(10).replace('-', '.')
        "$completed  ${if (finished) "读完" else "读到此刻"}${if (author.isBlank()) "" else " · $author"}"
    }

    companion object {
        private fun number(json: JSONObject?, name: String): Int? =
            if (json == null || json.isNull(name) || !json.has(name)) null else json.optInt(name).coerceAtLeast(0)

        fun minutes(seconds: Int?): String = when {
            seconds == null -> "—"
            seconds in 1..59 -> "<1"
            else -> "${seconds / 60}"
        }
    }
}
