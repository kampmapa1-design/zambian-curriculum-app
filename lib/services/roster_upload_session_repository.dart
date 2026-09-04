import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Whether a [ReportClass]'s roster (learner names, from score-sheet
/// uploads/Omitted Entry) has been marked "Complete Session Upload" — the
/// grade teacher confirming they're done adding students to this class,
/// per explicit request (2026-09-04). A small JSON sidecar file (classId
/// -> ISO timestamp), deliberately NOT a new `report_classes` SQLite
/// column: this app's schema is dropped and rebuilt from scratch on every
/// version bump (see DatabaseHelper's own doc comment), which would
/// silently wipe every already-entered class's real data — including
/// whatever a teacher has already captured on a real device — the next
/// time any unrelated part of the app needed a schema change. Same
/// reasoning, same pattern as MarkingSessionRepository.
class RosterUploadSessionRepository {
  static const _fileName = 'roster_upload_sessions.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<Map<String, String>> _all() async {
    final file = await _file();
    if (!await file.exists()) return {};
    try {
      return (jsonDecode(await file.readAsString()) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _persist(Map<String, String> all) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(all));
  }

  /// When this class's roster upload session was marked complete, or null
  /// if it never has been.
  Future<DateTime?> completedAt(int classId) async {
    final raw = (await _all())['$classId'];
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> markCompleted(int classId) async {
    final all = await _all();
    all['$classId'] = DateTime.now().toIso8601String();
    await _persist(all);
  }

  /// Reopens the session — a teacher realizing more names still need
  /// adding before really calling it done. Never destroys the roster
  /// itself, only the completion marker.
  Future<void> reopen(int classId) async {
    final all = await _all();
    all.remove('$classId');
    await _persist(all);
  }
}
