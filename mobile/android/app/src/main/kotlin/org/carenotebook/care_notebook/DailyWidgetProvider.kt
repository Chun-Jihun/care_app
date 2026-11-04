package org.carenotebook.care_notebook

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Widget cache is independent of vault keys and never contains the care DB. */
internal object DailyWidgetStorage {
    private const val alias = "care.daily-widget.v1"
    private fun file(context: Context) = AtomicFile(File(context.filesDir, "daily-widget.enc"))
    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) return null
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        }.generateKey()
    }
    fun write(context: Context, snapshot: JSONObject?) {
        val target = file(context)
        if (snapshot == null) {
            target.delete()
            KeyStore.getInstance("AndroidKeyStore").apply { load(null); if (containsAlias(alias)) deleteEntry(alias) }
            return
        }
        val plain = snapshot.toString().toByteArray(Charsets.UTF_8)
        require(snapshot.optInt("version") == 1 && plain.size <= 65536)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key(true)) }
        val sealed = cipher.iv + cipher.doFinal(plain)
        val stream = target.startWrite()
        try { stream.write(sealed); target.finishWrite(stream) } catch (error: Exception) { target.failWrite(stream); throw error }
    }
    fun read(context: Context): JSONObject? = runCatching {
        val data = file(context).openRead().use {
            require(it.channel.size() in 29L..65600L)
            it.readBytes()
        }
        require(data.size in 29..65600)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(false) ?: return null, GCMParameterSpec(128, data.copyOfRange(0, 12))) }
        JSONObject(String(cipher.doFinal(data.copyOfRange(12, data.size)), Charsets.UTF_8)).also { require(it.optInt("version") == 1) }
    }.getOrNull()
}

class DailyWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { render(context, manager, it) } }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) { render(context, manager, id) }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in listOf(Intent.ACTION_DATE_CHANGED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) refreshAll(context)
    }
    companion object {
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, DailyWidgetProvider::class.java)).forEach { render(context, manager, it) }
        }
        fun pin(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val manager = AppWidgetManager.getInstance(context)
            return manager.isRequestPinAppWidgetSupported && manager.requestPinAppWidget(ComponentName(context, DailyWidgetProvider::class.java), null, null)
        }
        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.daily_widget)
            val now = System.currentTimeMillis()
            val date = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(Date(now))
            val snapshot = DailyWidgetStorage.read(context)
            val labels = snapshot?.optJSONObject("labels")
            fun text(key: String, fallback: String) = labels?.optString(key)?.takeIf { it.isNotBlank() } ?: fallback
            var title = text("title", "간병수첩")
            var scope = text("scope", "선택한 수첩 · 입력한 기록 기준")
            var summary = "앱에서 홈 위젯을 켜 주세요."
            var next = "앱을 눌러 오늘 내용을 확인해 주세요."
            var updated = ""
            val days = snapshot?.optJSONArray("days")
            val matchingZone = snapshot?.optInt("timeZoneOffset", Int.MIN_VALUE) == TimeZone.getDefault().getOffset(now) / 60000
            val day = if (matchingZone && days != null) (0 until days.length()).mapNotNull { days.optJSONObject(it) }.firstOrNull { it.optString("day") == date } else null
            if (day != null) {
                title += " · " + SimpleDateFormat("MM/dd", Locale.getDefault()).format(Date(now))
                summary = "${text("pending", "오늘 할 일")}: ${day.optInt("pending")} · ${text("overdue", "지난 예정")}: ${day.optInt("overdue")}\n" +
                    "${text("intakes", "복용함 기록")}: ${if (day.isNull("intakes")) text("refresh", "기록 갱신 필요") else day.optInt("intakes").toString()}"
                val events = day.optJSONArray("events")
                val upcoming = if (events != null) (0 until events.length()).mapNotNull { events.optJSONObject(it) }.firstOrNull { it.optLong("at") >= now } else null
                next = if (upcoming != null) {
                    text("next", "다음 확인") + ": " + SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(upcoming.optLong("at"))) +
                        if (snapshot?.optBoolean("details") == true && upcoming.has("text")) " · " + upcoming.optString("text") else ""
                } else if (day.optBoolean("more") || day.optInt("pending") > 0 || day.optInt("overdue") > 0) {
                    text("open", "앱에서 확인")
                } else text("empty", "확인할 예정 없음")
                updated = text("updated", "마지막 갱신") + " " + SimpleDateFormat("MM/dd HH:mm", Locale.getDefault()).format(Date(snapshot!!.optLong("updated")))
            } else if (snapshot != null) {
                summary = text("refresh", "기록 갱신 필요")
                next = text("open", "앱에서 확인")
            }
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_scope, scope)
            views.setTextViewText(R.id.widget_summary, summary)
            views.setTextViewText(R.id.widget_next, next)
            views.setTextViewText(R.id.widget_updated, updated)
            val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180)
            val scale = context.resources.configuration.fontScale
            views.setViewVisibility(R.id.widget_scope, if (height < 190 * scale) View.GONE else View.VISIBLE)
            views.setViewVisibility(R.id.widget_title, if (height < 135 * scale) View.GONE else View.VISIBLE)
            views.setInt(R.id.widget_summary, "setMaxLines", 2)
            views.setInt(R.id.widget_next, "setMaxLines", if (height < 190 * scale) 1 else 2)
            views.setContentDescription(R.id.widget_root, listOf(title, scope, summary, next, updated).joinToString(". "))
            val open = Intent(context, MainActivity::class.java).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP }
            views.setOnClickPendingIntent(R.id.widget_root, PendingIntent.getActivity(context, 4719, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            manager.updateAppWidget(id, views)
        }
    }
}
