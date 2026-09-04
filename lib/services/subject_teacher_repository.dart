import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// On-device storage for each subject's teacher name — entered once via
/// Manage Subjects and reused automatically for every learner's report
/// form from then on (2026-09-04, per explicit request, matching a real
/// uploaded report form template's "Subject Teacher's Name" column). A
/// JSON sidecar file, keyed by [ReportSubject.id] (globally unique — no
/// need to also key by class), deliberately NOT a new `report_subjects`
/// SQLite column: this app's schema is dropped and rebuilt from scratch
/// on every version bump, which would wipe every already-entered class's
/// real data (scores included) on a real device — same reasoning as
/// MarkingSessionRepository/RosterUploadSessionRepository.
class SubjectTeacherRepository {
  static const _fileName = 'subject_teachers.json';

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

  Future<String?> teacherNameFor(int subjectId) async => (await _all())['$subjectId'];

  Future<void> setTeacherName(int subjectId, String? name) async {
    final all = await _all();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) {
      all.remove('$subjectId');
    } else {
      all['$subjectId'] = trimmed;
    }
    await _persist(all);
  }

  /// Every stored teacher name among [subjectIds], one lookup — used when
  /// generating a whole class's report forms at once, rather than one
  /// disk read per subject per learner.
  Future<Map<int, String>> teacherNamesFor(List<int> subjectIds) async {
    final all = await _all();
    return {
      for (final id in subjectIds)
        if (all['$id'] case final name?) id: name,
    };
  }
}
