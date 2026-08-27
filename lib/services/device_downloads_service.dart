import 'dart:io';

import 'package:flutter/services.dart';

/// Thrown when a real device-storage save isn't possible on this
/// platform/OS version — callers should fall back to the OS share sheet.
class DeviceDownloadsUnsupported implements Exception {
  const DeviceDownloadsUnsupported();
}

/// Saves a file into the device's actual public Downloads folder — visible
/// afterward in a Files app, the system Downloads app, notifications, etc.
/// — rather than only being reachable through the OS share sheet.
///
/// Backed by a small native MethodChannel (see MainActivity.kt) using
/// Android's MediaStore.Downloads API, which needs no runtime storage
/// permission on Android 10+ (API 29+) — effectively every phone in real
/// use as of 2026. Older Android versions, and any non-Android platform,
/// throw [DeviceDownloadsUnsupported]; callers should fall back to sharing
/// the file via `share_plus` in that case, same as before this existed.
class DeviceDownloadsService {
  static const _channel = MethodChannel('com.kampmapa1design.smartteacher/downloads');

  Future<void> saveToDownloads({
    required File file,
    required String fileName,
    String mimeType = 'application/pdf',
  }) async {
    if (!Platform.isAndroid) throw const DeviceDownloadsUnsupported();
    final bytes = await file.readAsBytes();
    try {
      await _channel.invokeMethod<String>('saveToDownloads', {
        'fileName': fileName,
        'mimeType': mimeType,
        'bytes': bytes,
      });
    } on PlatformException catch (e) {
      if (e.code == 'UNSUPPORTED') throw const DeviceDownloadsUnsupported();
      rethrow;
    } on MissingPluginException {
      throw const DeviceDownloadsUnsupported();
    }
  }
}
