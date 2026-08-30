import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/minutes_session.dart';

/// On-device storage for Minutes Maker sessions — same pattern as
/// MarkingScriptRepository: each session's captured page images live in
/// their own subdirectory, with a small JSON catalog alongside for
/// metadata. Fully offline: capturing and storing a session never needs a
/// connection; only Stage 5 (AI reconstruction) will.
class MinutesSessionRepository {
  static const _catalogFileName = 'minutes_sessions_catalog.json';
  static const _contentDirName = 'minutes_sessions';

  Future<Directory> _rootDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final contentDir = Directory(p.join(dir.path, _contentDirName));
    if (!await contentDir.exists()) await contentDir.create(recursive: true);
    return contentDir;
  }

  Future<File> _catalogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _catalogFileName));
  }

  Future<MinutesSessionCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return MinutesSessionCatalog.empty();
    try {
      return MinutesSessionCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return MinutesSessionCatalog.empty();
    }
  }

  Future<void> _saveCatalog(MinutesSessionCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  String _slug(String input) {
    final safe = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'meeting' : safe;
  }

  /// Copies captured page image files (from wherever the camera package
  /// wrote them) into this session's own permanent storage, in page order,
  /// and records it in the catalog.
  Future<MinutesSession> saveSession({
    required String meetingTitle,
    required DateTime meetingDate,
    required List<File> capturedPageFiles,
  }) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${_slug(meetingTitle)}';
    final sessionDir = Directory(p.join((await _rootDir()).path, id));
    if (!await sessionDir.exists()) await sessionDir.create(recursive: true);

    final pageFileNames = <String>[];
    for (var i = 0; i < capturedPageFiles.length; i++) {
      final fileName = 'page_${(i + 1).toString().padLeft(2, '0')}.jpg';
      await capturedPageFiles[i].copy(p.join(sessionDir.path, fileName));
      pageFileNames.add(fileName);
    }

    final session = MinutesSession(
      id: id,
      meetingTitle: meetingTitle,
      meetingDate: meetingDate,
      pageFileNames: pageFileNames,
      capturedAt: DateTime.now(),
    );

    final catalog = await loadCatalog();
    await _saveCatalog(MinutesSessionCatalog(sessions: [...catalog.sessions, session]));
    return session;
  }

  /// Full local paths to a session's page images, in page order.
  Future<List<File>> pageFilesFor(MinutesSession session) async {
    final root = await getApplicationDocumentsDirectory();
    final sessionDir = p.join(root.path, _contentDirName, session.id);
    return [for (final name in session.pageFileNames) File(p.join(sessionDir, name))];
  }

  Future<void> update(MinutesSession session) async {
    final catalog = await loadCatalog();
    final updated = [for (final s in catalog.sessions) if (s.id == session.id) session else s];
    await _saveCatalog(MinutesSessionCatalog(sessions: updated));
  }

  Future<void> remove(MinutesSession session) async {
    final root = await getApplicationDocumentsDirectory();
    final sessionDir = Directory(p.join(root.path, _contentDirName, session.id));
    if (await sessionDir.exists()) await sessionDir.delete(recursive: true);

    final catalog = await loadCatalog();
    await _saveCatalog(MinutesSessionCatalog(sessions: catalog.sessions.where((s) => s.id != session.id).toList()));
  }
}
