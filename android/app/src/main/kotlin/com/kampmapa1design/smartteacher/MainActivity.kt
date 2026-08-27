package com.kampmapa1design.smartteacher

import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Handles a "saveToDownloads" call from the Dart side (see
/// lib/services/device_downloads_service.dart) so a resource download can
/// land in the device's real public Downloads folder — visible in Files
/// apps, the system Downloads app, notifications, etc. — instead of only
/// being reachable through the OS share sheet. Uses MediaStore.Downloads
/// (Android 10 / API 29+), which needs no runtime storage permission.
/// Older Android versions aren't supported by this path; the Dart side
/// falls back to the share sheet there.
class MainActivity : FlutterActivity() {
    private val channelName = "com.kampmapa1design.smartteacher/downloads"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    try {
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                        val bytes = call.argument<ByteArray>("bytes")
                        if (fileName == null || bytes == null) {
                            result.error("BAD_ARGS", "fileName and bytes are required.", null)
                            return@setMethodCallHandler
                        }
                        val uriString = saveToDownloads(fileName, mimeType, bytes)
                        if (uriString != null) {
                            result.success(uriString)
                        } else {
                            result.error("UNSUPPORTED", "Saving to Downloads needs Android 10 or newer.", null)
                        }
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToDownloads(fileName: String, mimeType: String, bytes: ByteArray): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null

        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null

        resolver.openOutputStream(uri)?.use { out -> out.write(bytes) }
            ?: run {
                resolver.delete(uri, null, null)
                return null
            }

        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)

        return uri.toString()
    }
}
