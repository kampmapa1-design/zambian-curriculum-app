import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Report Form Pipeline, Stage 12 — "Approve & Sign". This app has no real
/// user-account/authentication system anywhere (every other feature is
/// offline-first, no login) — so "password-protected" here means a local,
/// on-device password the Head Teacher/Deputy sets once on this specific
/// device, gating one specific action (embedding their signature into a
/// batch of report forms), not a real multi-user account system. The
/// password is never stored in plain text (SHA-256 + a random per-setup
/// salt); the signature image lives in this app's own private documents
/// directory, the same protection every other captured photo in this app
/// already has — never a public/shared location, never returned by
/// [signatureImageBytes] except immediately after [verifyPassword]
/// succeeds (enforced by the calling screen, not re-checked here, the same
/// way every other password-gated action in this app trusts its own
/// screen's flow rather than re-validating at every read).
class HeadTeacherSignatureService {
  static const _metaFileName = 'head_teacher_signature_meta.json';
  static const _imageFileName = 'head_teacher_signature.png';

  Future<File> _metaFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _metaFileName));
  }

  Future<File> _imageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _imageFileName));
  }

  Future<bool> isSetUp() async => (await _metaFile()).exists();

  Future<String?> signedByName() async {
    final file = await _metaFile();
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return json['signedByName'] as String?;
    } catch (_) {
      return null;
    }
  }

  String _hash(String password, String salt) => sha256.convert(utf8.encode('$salt:$password')).toString();

  String _newSalt() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// First-time setup (or a deliberate reset) — sets the local password
  /// and stores the signature image. [signatureImageBytes] should already
  /// be a real signature photo/scan (captured the same way anything else
  /// in this app is — camera or device upload; this service only stores
  /// bytes, it doesn't capture them).
  Future<void> setup({
    required String password,
    required List<int> signatureImageBytes,
    required String signedByName,
  }) async {
    final salt = _newSalt();
    final metaFile = await _metaFile();
    await metaFile.writeAsString(jsonEncode({
      'passwordHash': _hash(password, salt),
      'salt': salt,
      'signedByName': signedByName,
      'setUpAt': DateTime.now().toIso8601String(),
    }));
    final imageFile = await _imageFile();
    await imageFile.writeAsBytes(signatureImageBytes, flush: true);
  }

  Future<bool> verifyPassword(String password) async {
    final file = await _metaFile();
    if (!await file.exists()) return false;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final salt = json['salt'] as String;
      final expected = json['passwordHash'] as String;
      return _hash(password, salt) == expected;
    } catch (_) {
      return false;
    }
  }

  /// The real signature image bytes — only ever call this right after
  /// [verifyPassword] returns true for this specific approval action. See
  /// this class's own doc comment on why that's enforced by convention
  /// (the calling screen's flow) rather than re-checked here.
  Future<List<int>?> signatureImageBytes() async {
    final file = await _imageFile();
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}
