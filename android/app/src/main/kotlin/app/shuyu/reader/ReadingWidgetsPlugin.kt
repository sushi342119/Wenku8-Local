package app.shuyu.reader

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject
import java.io.File

private const val widgetChannel = "org.mewx.wenku8/reading_widgets"
private const val widgetPreferences = "reading_widgets_v1"
private const val widgetDestination = "wenku_reading_surface"

/** Stable identities shared with ReadingVisualTheme in Dart. Live native fields
 * and activity charts remain separate from supporting art. The three old values
 * remain readable after app upgrades. */
private enum class ReadingWidgetTheme(
    val small: Int, val medium: Int, val large: Int,
) {
    archive(R.layout.reading_widget_archive_small, R.layout.reading_widget_archive_medium, R.layout.reading_widget_archive_large),
    shelf(R.layout.reading_widget_shelf_small, R.layout.reading_widget_shelf_medium, R.layout.reading_widget_shelf_large),
    editorial(R.layout.reading_widget_editorial_small, R.layout.reading_widget_editorial_medium, R.layout.reading_widget_editorial_large),
    constellation(R.layout.reading_widget_constellation_small, R.layout.reading_widget_constellation_medium, R.layout.reading_widget_constellation_large),
    signal(R.layout.reading_widget_signal_small, R.layout.reading_widget_signal_medium, R.layout.reading_widget_signal_large),
    score(R.layout.reading_widget_score_small, R.layout.reading_widget_score_medium, R.layout.reading_widget_score_large),
    ink(R.layout.reading_widget_ink_small, R.layout.reading_widget_ink_medium, R.layout.reading_widget_ink_large),
    festival(R.layout.reading_widget_festival_small, R.layout.reading_widget_festival_medium, R.layout.reading_widget_festival_large);

    fun layout(family: Int): Int = when (family) { 0 -> small; 1 -> medium; else -> large }
    val mediumUsesWeek: Boolean get() = this in listOf(shelf, editorial, signal, score)
    val showsWeekChart: Boolean get() = true

    companion object {
        fun read(json: JSONObject?): ReadingWidgetTheme {
            val id = json?.optString("themeId")?.takeIf { it.isNotBlank() }
                ?: json?.optString("palette")
            return when (id) {
                "cream", "paper" -> editorial
                "night" -> constellation
                else -> entries.firstOrNull { it.name == id } ?: archive
            }
        }
    }
}

class ReadingWidgetsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.NewIntentListener {
    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private val inbox = ReadingWidgetOpenInbox()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, widgetChannel).also { it.setMethodCallHandler(this) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null); channel = null
        inbox.pause()
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addOnNewIntentListener(this)
        offer(binding.activity.intent, false)
    }
    override fun onDetachedFromActivity() {
        activity?.removeOnNewIntentListener(this); activity = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onNewIntent(intent: Intent): Boolean = offer(intent, true)
    private fun offer(intent: Intent?, notify: Boolean): Boolean {
        val destination = intent?.getStringExtra(widgetDestination)
        val configuration = destination?.removePrefix("configure:")?.toIntOrNull()
        val configRequest = destination?.startsWith("configure:") == true && configuration != null && ReadingWidgetConfigureActivity.isPending(context, configuration)
        if (destination != "statistics" && destination != "moments" && destination != "continue" && destination != "excerpts" && !configRequest) return false
        intent?.removeExtra(widgetDestination)
        return inbox.offer(destination, notify) { target, completion ->
            val messenger = channel
            if (messenger == null) completion(false)
            else messenger.invokeMethod("openReadingSurface", target, object : MethodChannel.Result {
                override fun success(result: Any?) = completion(true)
                override fun error(code: String, message: String?, details: Any?) = completion(false)
                override fun notImplemented() = completion(false)
            })
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "cardsSupported" -> result.success(true)
            "completeConfiguration" -> try {
                val id = requireNotNull(call.argument<String>("widgetId")).toInt()
                val handled = ReadingWidgetConfigureActivity.complete(context, id, call.argument<Boolean>("confirmed") == true)
                result.success(null)
                if (handled) activity?.activity?.moveTaskToBack(true)
            } catch (_: Exception) { result.error("WIDGET_CONFIGURATION_FAILED", "小组件配置未能完成", null) }
            "publishCards" -> try {
                ReadingWidgetCards.publish(context, org.json.JSONArray(call.argument<List<Any>>("cards") ?: emptyList<Any>()).toString())
                result.success(null)
            } catch (_: Exception) { result.error("WIDGET_WRITE_FAILED", "小组件暂未更新", null) }
            "bindCard" -> try {
                ReadingWidgetCards.bind(context, requireNotNull(call.argument<String>("widgetId")).toInt(), requireNotNull(call.argument<String>("cardId")))
                result.success(null)
            } catch (_: Exception) { result.error("WIDGET_BIND_FAILED", "小组件未能设置", null) }
            "consumeOpenRequest" -> result.success(inbox.consume())
            "publishSnapshot" -> try {
                val json = JSONObject(requireNotNull(call.argument<String>("json")))
                require(json.getInt("version") == 1 && json.getJSONArray("week").length() == 7)
                // Privacy is enforced at the host boundary as well as in Dart.
                if (!json.optBoolean("showBookDetails")) json.put("currentBook", JSONObject.NULL)
                if (!json.optBoolean("showBookDetails")) json.optJSONObject("latestCompletion")?.let {
                    for (key in listOf("bookId", "title", "author", "coverPath")) it.put(key, JSONObject.NULL)
                }
                val directory = File(context.filesDir, "reading-desktop").apply { mkdirs() }
                val owned = JSONObject()
                val incoming = json.optJSONObject("desktopImages")
                try {
                    if (incoming != null) for (size in listOf("small", "medium", "large")) {
                        val source = File(incoming.getString(size)).canonicalFile
                        require(source.path.startsWith(File(context.applicationInfo.dataDir).canonicalPath + "/") && source.length() in 8..2_097_152)
                        val target = File(directory, "${java.util.UUID.randomUUID()}.png")
                        owned.put(size, target.path)
                        source.copyTo(target)
                    }
                    json.remove("desktopImages")
                    if (owned.length() == 3) json.put("desktopImages", owned)
                check(context.getSharedPreferences(widgetPreferences, Context.MODE_PRIVATE).edit()
                    .putString("snapshot", json.toString()).commit())
                } catch (error: Exception) {
                    owned.keys().forEach { File(owned.getString(it)).delete() }
                    throw error
                }
                val retained = owned.keys().asSequence().map { owned.getString(it) }.toSet()
                directory.listFiles()?.filter { it.path !in retained }?.forEach { it.delete() }
                ReadingWidgetProvider.refreshAll(context)
                result.success(null)
            } catch (_: Exception) { result.error("WIDGET_WRITE_FAILED", "桌面组件暂未更新，请重试", null) }
            else -> result.notImplemented()
        }
    }
}

class ReadingSmallWidget : ReadingWidgetProvider(0)
class ReadingMediumWidget : ReadingWidgetProvider(1)
class ReadingLargeWidget : ReadingWidgetProvider(2)

open class ReadingWidgetProvider(private val family: Int) : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == context.packageName + ".WIDGET_QUOTE_NEXT") {
            ReadingWidgetCards.next(context, intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1))
        } else super.onReceive(context, intent)
    }
    override fun onDeleted(context: Context, ids: IntArray) { ids.forEach { ReadingWidgetCards.remove(context, it) } }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) update(context, manager, id, family)
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        update(context, manager, id, family)
    }
    companion object {
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            listOf(ReadingSmallWidget::class.java, ReadingMediumWidget::class.java, ReadingLargeWidget::class.java)
                .forEachIndexed { family, type ->
                    manager.getAppWidgetIds(ComponentName(context, type)).forEach { update(context, manager, it, family) }
                }
        }
        private fun update(context: Context, manager: AppWidgetManager, id: Int, family: Int) {
            ReadingWidgetCards.render(context, manager, id, family)?.let { manager.updateAppWidget(id, it); return }
            val json = runCatching { JSONObject(context.getSharedPreferences(widgetPreferences, Context.MODE_PRIVATE)
                .getString("snapshot", "")!!) }.getOrNull()
            val theme = ReadingWidgetTheme.read(json)
            val content = ReadingWidgetContent(json)
            val design = ReadingWidgetDesignViews.id(json)
            if (design != "classic") {
                val bounds = manager.getAppWidgetOptions(id)
                val width = bounds.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, if (family == 0) 170 else 350).coerceAtLeast(140)
                val height = bounds.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, if (family == 2) 350 else 170).coerceAtLeast(140)
                val imagePath = json?.optJSONObject("desktopImages")?.optString(listOf("small", "medium", "large")[family])
                val image = imagePath?.takeIf { File(it).parentFile == File(context.filesDir, "reading-desktop") }
                    ?.let { BitmapFactory.decodeFile(it) }
                val designed = if (image == null) ReadingWidgetDesignViews.create(context, content, design, family, width, height)
                    else RemoteViews(context.packageName, R.layout.reading_widget_rendered).apply {
                        setImageViewBitmap(R.id.widget_rendered_face, image)
                        val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.ROOT).format(java.util.Date())
                        if (json?.optString("localDay") != today) {
                            setViewVisibility(R.id.widget_rendered_date, View.VISIBLE)
                            setTextViewText(R.id.widget_rendered_date, content.footer)
                        }
                        setContentDescription(R.id.widget_rendered_face, "轻小说文库。阅读 ${ReadingWidgetContent.minutes(content.todaySeconds)} 分钟，连续 ${content.streakText} 天。${content.footer}")
                    }
                val intent = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(widgetDestination, if (design == "memory") "moments" else "statistics")
                }
                designed.setOnClickPendingIntent(R.id.reading_widget_root, PendingIntent.getActivity(context, id, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                manager.updateAppWidget(id, designed)
                return
            }
            val views = RemoteViews(context.packageName, theme.layout(family))
            views.setTextViewText(R.id.widget_caption, content.footer)
            views.setTextViewText(R.id.widget_heatmap_heading, "近${ReadingWidgetHeatmap.weeks(family)}周")
            val options = manager.getAppWidgetOptions(id)
            val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH,
                if (family == 0) 170 else 350).coerceAtLeast(if (family == 0) 140 else 250)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT,
                if (family == 2) 350 else 170).coerceAtLeast(if (family == 2) 280 else 140)
            val chartHeight = when (family) { 0 -> height - 102; 1 -> height - 100; else -> 49 }
            views.setImageViewBitmap(R.id.widget_heatmap, ReadingWidgetHeatmapRenderer.render(
                content.heatmap, family, theme.name, context.resources.displayMetrics.density,
                (width - 20).toFloat(), chartHeight.toFloat()))
            views.setContentDescription(R.id.widget_heatmap, content.heatmap.description(family))
            views.setTextViewText(R.id.widget_as_of, content.footer)
            views.setTextViewText(R.id.widget_totals, "连续 ${content.streakText} 天  ·  今天 ${ReadingWidgetContent.minutes(content.todaySeconds)} 分钟  ·  ${content.weekDetail}")
            when (family) {
                0 -> {
                    views.setTextViewText(R.id.widget_heading, "连续阅读")
                    val streak = content.streak
                    views.setTextViewText(R.id.widget_value, content.streakText)
                    views.setTextViewText(R.id.widget_unit, "天")
                    if ((streak ?: 0) >= 100) {
                        views.setTextViewTextSize(R.id.widget_value, TypedValue.COMPLEX_UNIT_SP, if (streak!! >= 1000) 26f else 28f)
                    }
                    views.setTextViewText(R.id.widget_detail, content.smallDetail)
                }
                1 -> {
                    val streak = content.streak
                    views.setTextViewText(R.id.widget_heading, if (theme.mediumUsesWeek) "近7日阅读" else "连续阅读")
                    views.setTextViewText(R.id.widget_value, if (theme.mediumUsesWeek) content.weekMinutes else content.streakText)
                    views.setTextViewText(R.id.widget_unit, if (theme.mediumUsesWeek) "分钟" else "天")
                    if (theme.mediumUsesWeek && content.weekMinutes.length >= 4) {
                        views.setTextViewTextSize(R.id.widget_value, TypedValue.COMPLEX_UNIT_SP, if (content.weekMinutes.length >= 5) 24f else 28f)
                    } else if (!theme.mediumUsesWeek && (streak ?: 0) >= 100) {
                        views.setTextViewTextSize(R.id.widget_value, TypedValue.COMPLEX_UNIT_SP, if (streak!! >= 1000) 26f else 28f)
                    }
                    views.setTextViewText(R.id.widget_detail, if (theme.mediumUsesWeek) "连续 ${content.streakText} 天" else content.weekDetail)
                    val max = maxOf(300, content.week.maxOfOrNull { it.seconds ?: 0 } ?: 0)
                    val bars = listOf(R.id.widget_bar_0, R.id.widget_bar_1, R.id.widget_bar_2, R.id.widget_bar_3, R.id.widget_bar_4, R.id.widget_bar_5, R.id.widget_bar_6)
                    val labels = listOf(R.id.widget_day_0, R.id.widget_day_1, R.id.widget_day_2, R.id.widget_day_3, R.id.widget_day_4, R.id.widget_day_5, R.id.widget_day_6)
                    if (theme.showsWeekChart) for (i in 0..6) {
                        val day = content.week[i]
                        views.setProgressBar(bars[i], max, day.seconds ?: 0, false)
                        val date = day.date
                        views.setTextViewText(labels[i], if (date.length == 10) date.takeLast(2) else "—")
                        views.setContentDescription(bars[i], "${date}有效阅读${ReadingWidgetContent.minutes(day.seconds)}分钟")
                    }
                }
                else -> {
                    views.setTextViewText(R.id.widget_heading, "阅读纪念")
                    views.setTextViewText(R.id.widget_value, if (theme == ReadingWidgetTheme.festival || theme == ReadingWidgetTheme.score) content.completionTitle.replace("\n", "") else content.completionTitle)
                    views.setTextViewText(R.id.widget_detail, content.completionDetail)
                    views.setTextViewText(R.id.widget_caption, content.completionCaption)
                    val path = content.coverPath
                    val bitmap = if (path.isBlank()) null else decodeCover(path)
                    views.setViewVisibility(R.id.widget_cover_container, if (bitmap == null) View.GONE else View.VISIBLE)
                    views.setViewVisibility(R.id.widget_cover, if (bitmap == null) View.GONE else View.VISIBLE)
                    views.setViewVisibility(R.id.widget_bookmark, View.GONE)
                    if (bitmap != null) views.setImageViewBitmap(R.id.widget_cover, bitmap)
                }
            }
            val destination = if (family == 2) "moments" else "statistics"
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(widgetDestination, destination)
            }
            views.setOnClickPendingIntent(R.id.reading_widget_root, PendingIntent.getActivity(context, id, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            // A full replacement releases the previous cover bitmap allocation.
            manager.updateAppWidget(id, views)
        }
        internal fun decodeCover(path: String): Bitmap? = runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val options = BitmapFactory.Options().apply {
                inPreferredConfig = Bitmap.Config.RGB_565
                var sample = 1
                while (bounds.outWidth / sample > 360 || bounds.outHeight / sample > 540) sample *= 2
                inSampleSize = sample
            }
            BitmapFactory.decodeFile(path, options)
        }.getOrNull()
    }
}
