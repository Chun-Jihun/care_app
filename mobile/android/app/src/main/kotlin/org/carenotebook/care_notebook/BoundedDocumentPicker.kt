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

internal class BoundedDocumentPicker(private val activity: ComponentActivity) {
    private data class Request(val maxBytes: Long, val installBytes: Long, val result: MethodChannel.Result)
    private var pending: Request? = null
    private val picker = activity.registerForActivityResult(ActivityResultContracts.OpenDocument(), ::onDocument)

    fun open(maxBytes: Long, installBytes: Long, result: MethodChannel.Result) {
        if (pending != null || maxBytes !in 1L until Long.MAX_VALUE || installBytes !in 0L..maxBytes) {
            result.error("documentOpenFailed", null, null)
            return
        }
        pending = Request(maxBytes, installBytes, result)
        try {
            picker.launch(arrayOf("*/*"))
        } catch (_: Exception) {
            finish(null, "documentOpenFailed")
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
            var missingBytes: Long? = null
            try {
                require(uri.scheme == ContentResolver.SCHEME_CONTENT)
                val resolver = activity.contentResolver
                val size = try {
                    resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
                        val column = it.getColumnIndex(OpenableColumns.SIZE)
                        if (column >= 0 && it.moveToFirst() && !it.isNull(column)) {
                            it.getLong(column).takeIf { bytes -> bytes >= 0 }
                        } else null
                    }
                } catch (_: UnsupportedOperationException) {
                    null
                }
                file = stageBoundedDocument(activity.cacheDir, size, request.maxBytes, request.installBytes) {
                    resolver.openInputStream(uri) ?: throw IOException()
                }
            } catch (_: DocumentTooLarge) {
                error = "documentTooLarge"
            } catch (e: DocumentSpaceInsufficient) {
                error = "documentSpaceInsufficient"
                missingBytes = e.missingBytes
            } catch (_: Exception) {
                error = "documentOpenFailed"
            }
            activity.runOnUiThread { finish(file, error, missingBytes) }
        }.start()
    }

    private fun finish(file: File?, error: String? = null, missingBytes: Long? = null) {
        val request = pending
        pending = null
        if (error != null || activity.isDestroyed || request == null) file?.delete()
        if (request == null || activity.isDestroyed) return
        if (error != null) request.result.error(error, null, missingBytes)
        else request.result.success(file?.absolutePath)
    }
}

internal class DocumentTooLarge : IOException()
internal class DocumentSpaceInsufficient(val missingBytes: Long) : IOException()

internal fun stageBoundedDocument(
    cache: File,
    size: Long?,
    maxBytes: Long,
    installBytes: Long,
    open: () -> InputStream,
): File {
    if (size != null && size > maxBytes) throw DocumentTooLarge()
    // Keep room for the extracted files and for the notebook to keep writing.
    val capacity = cache.usableSpace - installBytes - 8L * 1024 * 1024
    val needed = maxOf(1L, size ?: 1L)
    if (needed > capacity) throw DocumentSpaceInsufficient(needed - capacity)
    val limit = minOf(maxBytes, capacity)
    val stage = File.createTempFile("care-document-import-", ".tmp", cache)
    var complete = false
    try {
        open().use { input ->
            stage.outputStream().use { copyBoundedDocument(input, it, limit) }
        }
        complete = true
        return stage
    } catch (e: DocumentTooLarge) {
        if (limit < maxBytes) throw DocumentSpaceInsufficient(maxBytes - limit)
        throw e
    } finally {
        if (!complete) stage.delete()
    }
}

private fun copyBoundedDocument(input: InputStream, output: OutputStream, limit: Long) {
    val buffer = ByteArray(8192)
    var remaining = limit
    while (true) {
        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining + 1).toInt())
        if (count < 0) return
        if (count > remaining) throw DocumentTooLarge()
        output.write(buffer, 0, count)
        remaining -= count
    }
}
