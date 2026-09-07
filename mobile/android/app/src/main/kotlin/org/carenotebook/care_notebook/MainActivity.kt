package org.carenotebook.care_notebook

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.TimeZone

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
