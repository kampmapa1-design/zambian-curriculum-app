import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/marking_session.dart';

/// On-device storage for the one active [MarkingSession], if any — a
/// single small JSON file, same dual-retention-adjacent pattern as
/// MarkingScriptRepository's own catalog file, deliberately NOT a SQLite
/// table: this app's SQLite schema is rebuilt from scratch on every
/// version bump (see DatabaseHelper's own doc comment on why), which would
/// silently wipe an in-progress session the next time any unrelated part
/// of the app needed a schema change. A plain file has no such risk.
///
/// At most one session is ever active at a time — starting a new one
/// (see [start]) simply overwrites whatever was there.
class MarkingSessionRepository {
  static const _fileName = 'marking_session.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  /// The active session, if one exists — see [MarkingSession]'s own doc
  /// comment on why this is what actually makes "leave the app, come back,
  /// resume exactly where I was" work. A corrupt/unreadable file is
  /// treated the same as no session, rather than throwing and blocking
  /// capture entirely.
  Future<MarkingSession?> getActive() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      return MarkingSession.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> start(MarkingSession session) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(session.toJson()));
  }

  /// Ends the active session, if any — called once its stated target
  /// script count is reached (see ScriptBatchCaptureScreen), or when a
  /// teacher explicitly changes subject/marking key mid-session (see
  /// MarkingQueueScreen's "Change subject / marking key" action). The next
  /// "Upload Script" after this asks fresh, same as if no session had ever
  /// existed.
  Future<void> end() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
