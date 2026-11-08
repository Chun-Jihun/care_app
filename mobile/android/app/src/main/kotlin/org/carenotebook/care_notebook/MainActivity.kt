package org.carenotebook.care_notebook

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.StatFs
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.TimeZone

class MainActivity : FlutterFragmentActivity() {
    private val visitPlayback = VisitAudioPlayback()
    private val backupPicker = BackupDocumentPicker(this)

    override fun onPause() {
        visitPlayback.stop()
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onPause()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.carenotebook/visit_audio").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "keepScreenOn" -> {
                        if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    "startPlayback" -> { visitPlayback.start(); result.success(null) }
                    "writePlayback" -> result.success(visitPlayback.write(
                        checkNotNull(call.argument<ByteArray>("pcm")), checkNotNull(call.argument<Int>("offset"))))
                    "playbackDrained" -> result.success(visitPlayback.drained())
                    "stopPlayback" -> { visitPlayback.stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("unavailable", "기기 작업을 완료하지 못했습니다.", null) }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.carenotebook/privacy").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "protectDirectory" -> {
                        val path = File(call.argument<String>("path") ?: "").canonicalFile
                        val allowed = File(applicationInfo.dataDir).canonicalPath + File.separator
                        require(path.path.startsWith(allowed))
                        result.success(null)
                    }
                    "timeZone" -> result.success(TimeZone.getDefault().id)
                    "availableVaultBytes" -> result.success(StatFs(filesDir.path).availableBytes)
                    "pickBackup" -> backupPicker.open(call.arguments as Int, result)
                    "dailyWidgetAvailable" -> result.success(true)
                    "pinDailyWidget" -> result.success(DailyWidgetProvider.pin(this))
                    "updateDailyWidget" -> {
                        val data = call.argument<Map<String, Any?>>("snapshot")
                        DailyWidgetStorage.write(this, data?.let { org.json.JSONObject(it) })
                        DailyWidgetProvider.refreshAll(this)
                        result.success(null)
                    }
                    "dial" -> {
                        val number = call.argument<String>("number") ?: ""
                        require(number.matches(Regex("[+0-9 ()-]{2,32}")))
                        startActivity(Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null)))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("unavailable", "기기 작업을 완료하지 못했습니다.", null) }
        }
    }
}
