package org.mewx.wenku8_flutter

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Independent instance bindings and local excerpt cursors; no Flutter needed for buttons. */
internal object ReadingWidgetCards {
    private fun prefs(c: Context) = c.getSharedPreferences("reading_cards_v1", Context.MODE_PRIVATE)
    fun cards(c: Context): JSONArray = runCatching { JSONArray(prefs(c).getString("cards", "[]")) }.getOrDefault(JSONArray())
    private fun all(a: JSONArray) = (0 until a.length()).map { a.getJSONObject(it) }
    private fun card(c: Context, id: Int) = all(cards(c)).firstOrNull { it.optString("id") == prefs(c).getString("binding_$id", null) }
    fun bind(c: Context, id: Int, cardId: String) {
        require(AppWidgetManager.getInstance(c).getAppWidgetInfo(id)?.provider?.packageName == c.packageName)
        require(all(cards(c)).any { it.optString("id") == cardId })
        check(prefs(c).edit().putString("binding_$id", cardId).remove("quote_$id").commit())
        ReadingWidgetProvider.refreshAll(c)
    }
    fun remove(c: Context, id: Int) { prefs(c).edit().remove("binding_$id").remove("quote_$id").apply() }
    fun publish(c: Context, input: String) {
        val next = JSONArray(input)
        val directory = File(c.filesDir, "reading-cards").apply { mkdirs() }
        val retained = mutableSetOf<String>(); val created = mutableListOf<File>(); val old = all(cards(c))
        try {
            for (card in all(next)) {
                require(card.getString("id").matches(Regex("[a-zA-Z0-9_-]{1,64}")))
                val previous = old.firstOrNull { it.optString("id") == card.getString("id") }
                val images = card.getJSONObject("images"); val sources = JSONObject(images.toString())
                for (size in listOf("small", "medium", "large")) for (mode in listOf("light", "dark")) {
                    val key = "${size}_$mode"; val source = File(images.getString(key)).canonicalFile
                    sources.put(key, source.path)
                    require(source.path.startsWith(File(c.applicationInfo.dataDir).canonicalPath + "/") && source.length() in 8..2_097_152)
                    val reuse = previous?.optJSONObject("images")?.optString(key)?.takeIf {
                        previous.optJSONObject("sources")?.optString(key) == source.path && File(it).parentFile == directory && File(it).isFile }
                    val path = reuse ?: File(directory, "${java.util.UUID.randomUUID()}.png").also { source.copyTo(it); created.add(it) }.path
                    images.put(key, path); retained.add(path)
                }
                card.put("sources", sources)
            }
            check(prefs(c).edit().putString("cards", next.toString()).commit())
        } catch (error: Exception) { created.forEach { it.delete() }; throw error }
        directory.listFiles()?.filter { it.path !in retained }?.forEach { it.delete() }
        ReadingWidgetProvider.refreshAll(c)
    }
    fun next(c: Context, id: Int) {
        val quotes = card(c, id)?.optJSONArray("quotes") ?: return
        if (quotes.length() < 2) return
        val selected = prefs(c).getString("quote_$id", null)
        val index = all(quotes).indexOfFirst { it.optString("id") == selected }.coerceAtLeast(0)
        prefs(c).edit().putString("quote_$id", quotes.getJSONObject((index + 1) % quotes.length()).getString("id")).commit()
        ReadingWidgetProvider.refreshAll(c)
    }
    private fun open(c: Context, id: Int, route: String): PendingIntent = PendingIntent.getActivity(c, id,
        Intent(c, MainActivity::class.java).setAction("reading.$route.$id")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("wenku_reading_surface", route), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    fun render(c: Context, manager: AppWidgetManager, id: Int, family: Int): RemoteViews? {
        val card = card(c, id) ?: return null
        val size = listOf("small", "medium", "large")[family]; val appearance = card.optString("appearance", "system")
        val dark = appearance == "dark" || appearance == "system" && c.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        fun icon(mode: String): Icon {
            val path = card.getJSONObject("images").getString("${size}_$mode")
            require(File(path).parentFile == File(c.filesDir, "reading-cards"))
            val bytes = File(path).readBytes(); return Icon.createWithData(bytes, 0, bytes.size)
        }
        return runCatching {
            val views = RemoteViews(c.packageName, R.layout.reading_widget_rendered)
            if (Build.VERSION.SDK_INT >= 31 && appearance == "system") views.setIcon(R.id.widget_rendered_face, "setImageIcon", icon("light"), icon("dark"))
            else views.setImageViewIcon(R.id.widget_rendered_face, icon(if (dark) "dark" else "light"))
            val design = card.getString("design")
            val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.ROOT).format(java.util.Date())
            if (design != "quote" && card.optString("localDay") != today) {
                views.setViewVisibility(R.id.widget_rendered_date, View.VISIBLE)
                views.setTextViewText(R.id.widget_rendered_date, "截至 " + card.optString("localDay").replace('-', '.'))
            }
            val route = when (design) { "memory" -> "moments"; "quote" -> "excerpts"; else -> "statistics" }
            views.setOnClickPendingIntent(R.id.reading_widget_root, open(c, id, route))
            views.setContentDescription(R.id.widget_rendered_face, card.getString("name"))
            if (family == 2 && card.optBoolean("hasRecent")) {
                views.setViewVisibility(R.id.widget_recent_action, View.VISIBLE)
                views.setOnClickPendingIntent(R.id.widget_recent_action, open(c, id, "continue"))
            }
            if (design == "quote") {
                val quotes = card.optJSONArray("quotes") ?: JSONArray(); val selected = prefs(c).getString("quote_$id", null)
                val quote = all(quotes).firstOrNull { it.optString("id") == selected } ?: quotes.optJSONObject(0)
                val bounds = manager.getAppWidgetOptions(id)
                val width = bounds.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, if (family == 0) 170 else 364)
                val height = bounds.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, if (family == 2) 382 else 170)
                val sx = width / (if (family == 0) 170f else 364f); val sy = height / (if (family == 2) 382f else 170f)
                fun px(v: Float) = (v * c.resources.displayMetrics.density).toInt()
                views.setViewVisibility(R.id.widget_quote_panel, View.VISIBLE)
                views.setViewPadding(R.id.widget_quote_panel, px((if (family == 1) 30 else 16) * sx), px((if (family == 2) 230 else if (family == 0) 62 else 50) * sy), px(16 * sx), px((if (family == 2) 44 else 36) * sy))
                views.setTextViewText(R.id.widget_quote_text, quote?.optString("text") ?: "在阅读中留下喜欢的句子")
                views.setTextViewText(R.id.widget_quote_source, quote?.optString("source") ?: "")
                views.setTextViewTextSize(R.id.widget_quote_text, TypedValue.COMPLEX_UNIT_DIP, (if (family == 2) 20 else if (family == 1) 16 else 14) * sx)
                if (family == 2 && quotes.length() > 0) { views.setViewVisibility(R.id.widget_quote_count, View.VISIBLE); views.setTextViewText(R.id.widget_quote_count, "共 ${quotes.length()} 条摘录") }
                for (view in listOf(R.id.widget_quote_text, R.id.widget_quote_source, R.id.widget_quote_count)) {
                    if (Build.VERSION.SDK_INT >= 31 && appearance == "system") views.setColorInt(view, "setTextColor", Color.rgb(32,35,41), Color.rgb(242,239,232))
                    else views.setTextColor(view, if (dark) Color.rgb(242,239,232) else Color.rgb(32,35,41))
                }
                if (quotes.length() > 1) {
                    views.setViewVisibility(R.id.widget_quote_next, View.VISIBLE)
                    val intent = Intent(c.packageName + ".WIDGET_QUOTE_NEXT").setComponent(manager.getAppWidgetInfo(id).provider).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    views.setOnClickPendingIntent(R.id.widget_quote_next, PendingIntent.getBroadcast(c, id, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                }
            }
            views
        }.getOrNull()
    }
}

class ReadingWidgetConfigureActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private var registered = false
    private val completed = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1) == widgetId) finishIfCompleted()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); setResult(RESULT_CANCELED)
        widgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (AppWidgetManager.getInstance(this).getAppWidgetInfo(widgetId)?.provider?.packageName != packageName) { finish(); return }
        if (savedInstanceState == null) requests(this).edit().putString(widgetId.toString(), "pending").commit()
        if (finishIfCompleted()) return
        ContextCompat.registerReceiver(this, completed, IntentFilter(packageName + CONFIGURED), ContextCompat.RECEIVER_NOT_EXPORTED)
        registered = true
        // Reuse the app's existing engine, state and themed Flutter page rather
        // than creating another reader process or a native imitation of its UI.
        startActivity(Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("wenku_reading_surface", "configure:$widgetId"))
    }

    override fun onResume() { super.onResume(); finishIfCompleted() }
    override fun onDestroy() {
        if (registered) unregisterReceiver(completed)
        super.onDestroy()
    }

    private fun finishIfCompleted(): Boolean {
        val status = requests(this).getString(widgetId.toString(), null)
        if (status != "confirmed" && status != "cancelled") return false
        requests(this).edit().remove(widgetId.toString()).commit()
        setResult(if (status == "confirmed") RESULT_OK else RESULT_CANCELED,
            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId))
        finish(); return true
    }

    companion object {
        private const val CONFIGURED = ".WIDGET_CONFIGURED"
        private fun requests(c: Context) = c.getSharedPreferences("reading_widget_configuration", Context.MODE_PRIVATE)
        fun isPending(c: Context, id: Int) = requests(c).getString(id.toString(), null) == "pending"
        fun complete(c: Context, id: Int, confirmed: Boolean): Boolean {
            if (!isPending(c, id)) return false
            check(requests(c).edit().putString(id.toString(), if (confirmed) "confirmed" else "cancelled").commit())
            c.sendBroadcast(Intent(c.packageName + CONFIGURED).setPackage(c.packageName)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id))
            return true
        }
    }
}
