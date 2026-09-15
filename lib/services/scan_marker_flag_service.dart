import '../models/marking_script.dart';
import 'marking_script_repository.dart';

/// Stage 5 of School Network ("flagged-entry check", added 2026-09-13) —
/// entirely on-device, since Scan Marker data never leaves the device.
/// There's no single per-script "needs review" boolean in this app (a
/// real gap, confirmed before building this): the review signal lives per
/// answer (see [reviewSeverityFor]), so "does this teacher have anything
/// still needing review for this class/subject" means scanning each
/// script's own [MarkingScript.gradedAnswers]. Matching a Scan Marker
/// script to a School Network class/subject is by free-text NAME, not a
/// real link (MarkingScript.classLevel/subjectName have never been tied
/// to any class entity) — a real, known limitation, not a bug: a typo or
/// naming mismatch between what was typed during capture and the class's
/// published `classGrade` will silently miss a match, same fragility this
/// app already has anywhere else it does this kind of free-text matching.
class ScanMarkerFlagService {
  ScanMarkerFlagService({MarkingScriptRepository? repository}) : _repository = repository ?? MarkingScriptRepository();

  final MarkingScriptRepository _repository;

  static String _normalize(String value) => value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// True if this teacher has any script matching [classLevel]/
  /// [subjectName] that's graded but not yet reviewed (status ==
  /// [MarkingScriptStatus.graded]) AND has at least one answer a real
  /// person hasn't confirmed (amber under [reviewSeverityFor]).
  Future<bool> hasUnresolvedFlags({required String classLevel, required String subjectName}) async {
    final catalog = await _repository.loadCatalog();
    final wantClass = _normalize(classLevel);
    final wantSubject = _normalize(subjectName);
    for (final script in catalog.scripts) {
      if (script.status != MarkingScriptStatus.graded) continue;
      if (_normalize(script.classLevel) != wantClass) continue;
      if (_normalize(script.subjectName) != wantSubject) continue;
      final answers = script.gradedAnswers;
      if (answers == null) continue;
      if (answers.any((a) => reviewSeverityFor(a) == ReviewSeverity.amber)) return true;
    }
    return false;
  }
}
