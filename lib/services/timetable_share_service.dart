import 'dart:io';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

enum TimetableShareOutcome {
  /// Mobile: WhatsApp (or the OS share sheet, if WhatsApp isn't
  /// installed) opened with the file attached — nothing more for the
  /// caller to tell the user.
  shared,

  /// Web: the file was downloaded and WhatsApp's chat picker opened in a
  /// new tab, but a browser can't attach a file to WhatsApp itself — the
  /// caller should tell the user to attach the just-downloaded file by
  /// hand.
  webDownloadedAndWhatsAppOpened,
}

/// Timetable Generation, Stage 14 (added 2026-09-14) — "Share to
/// WhatsApp," mirroring the wa.me-deep-link-then-share-sheet pattern
/// Test Submission already uses (see test_submission_screen.dart), but
/// with no specific recipient number: `https://wa.me/?text=...` (no
/// number) opens WhatsApp's own chat list so the user picks who to send
/// to themselves — a real, disclosed choice, not an automated send to
/// anyone. Web can't attach a file to WhatsApp Web programmatically, so
/// there the honest equivalent is: download the file, open WhatsApp,
/// and say so.
class TimetableShareService {
  Future<TimetableShareOutcome> shareToWhatsApp({required Uint8List bytes, required String fileName, required String caption}) async {
    final waUri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(caption)}');

    if (kIsWeb) {
      await FileSaver.instance.saveFile(name: p.withoutExtension(fileName), bytes: bytes, fileExtension: p.extension(fileName).replaceFirst('.', ''), mimeType: MimeType.pdf);
      await launchUrl(waUri, mode: LaunchMode.externalApplication);
      return TimetableShareOutcome.webDownloadedAndWhatsAppOpened;
    }

    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    final opened = await launchUrl(waUri, mode: LaunchMode.externalApplication);
    if (opened) {
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'Attach to the WhatsApp chat that just opened.'));
    } else {
      // WhatsApp isn't installed or the launch failed — fall back to the
      // normal OS share sheet rather than a dead end.
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: caption));
    }
    return TimetableShareOutcome.shared;
  }
}
