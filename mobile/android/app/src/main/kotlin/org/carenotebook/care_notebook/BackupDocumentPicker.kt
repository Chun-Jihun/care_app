package org.carenotebook.care_notebook

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

internal class BackupDocumentPicker(private val activity: ComponentActivity) {
    private data class Request(val limit: Int, val result: MethodChannel.Result)
    private var pending: Request? = null
    private val picker = activity.registerForActivityResult(ActivityResultContracts.OpenDocument(), ::onDocument)

    fun open(limit: Int, result: MethodChannel.Result) {
        if (pending != null || limit !in 1 until Int.MAX_VALUE) {
            result.error("backupOpenFailed", null, null)
            return
        }
        pending = Request(limit, result)
        try {
            picker.launch(arrayOf("*/*"))
        } catch (_: Exception) {
            finish(null, "backupOpenFailed")
        }
    }

    private fun onDocument(uri: Uri?) {
        val request = pending ?: return
        if (uri == null) {
            finish(null)
            return
        }
        Thread {
            var file: File? = null
            var error: String? = null
            try {
                require(uri.scheme == ContentResolver.SCHEME_CONTENT)
                val resolver = activity.contentResolver
                val size = resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
                    val column = it.getColumnIndex(OpenableColumns.SIZE)
                    if (column >= 0 && it.moveToFirst() && !it.isNull(column)) it.getLong(column) else null
                }
                if (size != null && size > request.limit) throw BackupFileTooLarge()
                val stage = File.createTempFile("care-backup-import-", ".tmp", activity.cacheDir)
                file = stage
                val input = resolver.openInputStream(uri) ?: throw IOException()
                input.use { source ->
                    stage.outputStream().use { copyBackupDocument(source, it, request.limit) }
                }
            } catch (_: BackupFileTooLarge) {
                error = "backupFileTooLarge"
            } catch (_: Exception) {
                error = "backupOpenFailed"
            }
            activity.runOnUiThread { finish(file, error) }
        }.start()
    }

    private fun finish(file: File?, error: String? = null) {
        val request = pending
        pending = null
        if (error != null || activity.isDestroyed || request == null) file?.delete()
        if (request == null || activity.isDestroyed) return
        if (error != null) request.result.error(error, null, null)
        else request.result.success(file?.absolutePath)
    }
}

internal class BackupFileTooLarge : IOException()

internal fun copyBackupDocument(input: InputStream, output: OutputStream, limit: Int) {
    val buffer = ByteArray(8192)
    var remaining = limit
    while (true) {
        val count = input.read(buffer, 0, minOf(buffer.size, remaining + 1))
        if (count < 0) return
        if (count > remaining) throw BackupFileTooLarge()
        output.write(buffer, 0, count)
        remaining -= count
    }
}
