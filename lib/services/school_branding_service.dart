import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';

class SchoolBrandingException implements Exception {
  final String message;
  const SchoolBrandingException(this.message);
  @override
  String toString() => message;
}

/// Timetable Generation, Stage 12 (added 2026-09-14) — "school-branded,
/// pin-ready export." A school's logo lives at the fixed Storage path
/// `schools/{schoolId}/logo` — existence IS the signal ("if one is
/// stored"), so there's deliberately no separate Firestore flag to keep
/// in sync: uploading replaces it, removing deletes it, and export code
/// just tries to fetch it and treats "not found" as "no logo set,
/// export with the school name only" rather than an error. See
/// firebase/storage.rules for the write gate (school leadership/
/// administrator only) and read gate (any member of that school).
class SchoolBrandingService {
  SchoolBrandingService({FirebaseStorage? storage}) : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  Reference _logoRef(String schoolId) => _storage.ref('schools/$schoolId/logo');

  /// Null means no logo is stored — a normal, expected state, not an
  /// error. Any other failure (permission, network) is swallowed too:
  /// a broken logo fetch should never block a timetable export, which is
  /// the only place this is meant to be called from besides the upload
  /// screen itself.
  Future<Uint8List?> getLogoBytes(String schoolId) async {
    try {
      return await _logoRef(schoolId).getData(5 * 1024 * 1024);
    } catch (_) {
      return null;
    }
  }

  Future<void> uploadLogo({required String schoolId, required Uint8List bytes, required String contentType}) async {
    try {
      await _logoRef(schoolId).putData(bytes, SettableMetadata(contentType: contentType));
    } on FirebaseException catch (e) {
      throw SchoolBrandingException(e.message ?? 'Could not upload the logo.');
    }
  }

  Future<void> removeLogo(String schoolId) async {
    try {
      await _logoRef(schoolId).delete();
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return;
      throw SchoolBrandingException(e.message ?? 'Could not remove the logo.');
    }
  }
}
