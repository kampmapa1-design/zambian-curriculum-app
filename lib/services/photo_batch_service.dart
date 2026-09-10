import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'auth_service.dart';

class PhotoBatchUnavailable implements Exception {
  final String message;
  const PhotoBatchUnavailable(this.message);
  @override
  String toString() => message;
}

/// "Share the Photo Batch" (Scan Marker, 2026-09-10, per explicit
/// request) — "the finished processed pictures of a cohort with a number
/// of scripts... the sharing options... should include all the usual
/// sharing means and this should include a link that can be pasted in
/// any other AI platform to process the marking from there if so
/// desired." The batch is exactly what was actually sent to AI grading
/// for this cohort: every captured page, across every script, combined
/// into one PDF (one photo per page).
///
/// Two ways to share, both from the same composed PDF: [composePdf] alone
/// feeds the normal OS share sheet (share_plus, any app — text/email/
/// WhatsApp/Drive/etc., same as every other export in this app);
/// [uploadAndGetLink] additionally uploads it to this device's own
/// uid-scoped Storage path and mints a real, 30-day link — long enough to
/// actually be pasted somewhere later, unlike the 15-minute links this
/// app uses elsewhere for on-demand downloads (see getPhotoBatchUrl's own
/// Cloud Function comment).
class PhotoBatchService {
  PhotoBatchService({FirebaseStorage? storage, FirebaseFunctions? functions})
      : _providedStorage = storage,
        _providedFunctions = functions;

  // Lazy (same fix applied to TopicSearchService/CdcResourcesService
  // earlier this session — see their own doc comments): resolving
  // FirebaseStorage.instance/FirebaseFunctions.instance needs
  // Firebase.initializeApp() to have already run, which composePdf (pure
  // on-device PDF assembly) has no need for at all — only
  // uploadAndGetLink's real network calls do.
  final FirebaseStorage? _providedStorage;
  final FirebaseFunctions? _providedFunctions;
  FirebaseStorage get _storage => _providedStorage ?? FirebaseStorage.instance;
  FirebaseFunctions get _functions => _providedFunctions ?? FirebaseFunctions.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Combines every image in [imageFiles], in order, into one PDF — one
  /// photo per page. Same "viewable image PDF" pattern already used for
  /// Test Submission's own backup bundle (see TestSubmissionDocumentService
  /// .generateImageBundle) — written fresh here rather than reused, since
  /// that one is tied to one TestSubmission's own single directory, not a
  /// flat file list drawn from across several scripts' own separate
  /// per-script directories (see MarkingScriptRepository.pageFilesFor).
  /// A file that no longer exists (e.g. photos already discarded for
  /// storage, see MarkingScript.photosDiscarded) is silently skipped
  /// rather than failing the whole batch.
  Future<File> composePdf(List<File> imageFiles, {required String title}) async {
    final doc = pw.Document();
    for (final file in imageFiles) {
      if (!await file.exists()) continue;
      final image = pw.MemoryImage(await file.readAsBytes());
      doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, build: (context) => pw.Center(child: pw.Image(image))));
    }
    final bytes = await doc.save();
    final dir = await getTemporaryDirectory();
    final safeName = title.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    final file = File(p.join(dir.path, '${safeName.isEmpty ? 'photo_batch' : safeName}_photo_batch.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Uploads [pdfFile] to this device's own uid-scoped Storage path (see
  /// storage.rules — a real client-write rule specifically for this, so a
  /// large multi-script PDF never has to pass through a Callable
  /// Function's own payload-size ceiling as base64) and returns a real,
  /// sharable link.
  Future<String> uploadAndGetLink(File pdfFile) async {
    if (!await isOnline) {
      throw const PhotoBatchUnavailable("You're offline. Connect to the internet to create a shareable link.");
    }
    final user = await AuthService.instance.ensureSignedIn();
    final batchId = DateTime.now().millisecondsSinceEpoch.toString();
    final storagePath = 'photo_batches/${user.uid}/$batchId/batch.pdf';

    try {
      await _storage.ref(storagePath).putFile(pdfFile, SettableMetadata(contentType: 'application/pdf'));
    } on FirebaseException catch (e) {
      throw PhotoBatchUnavailable(e.message ?? 'Could not upload the photo batch.');
    }

    try {
      final callable = _functions.httpsCallable(
        'getPhotoBatchUrl',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
      );
      final result = await callable.call<Map<Object?, Object?>>({'storagePath': storagePath});
      final url = result.data['url'];
      if (url is! String || url.isEmpty) throw const PhotoBatchUnavailable('The link came back empty.');
      return url;
    } on FirebaseFunctionsException catch (e) {
      throw PhotoBatchUnavailable(e.message ?? 'Could not create a link for the photo batch.');
    }
  }
}
