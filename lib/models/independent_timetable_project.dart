/// "Build Timetable for Another School" (added 2026-09-16) — a fully
/// independent timetable-building project, never connected to the
/// caller's own subscribed school: no School Network membership, no real
/// registered teacher roster, no subscription-tier gate. See
/// `IndependentTimetableService`'s doc comment for the full picture.
class IndependentTimetableProject {
  final String id;
  final String institutionName;

  const IndependentTimetableProject({required this.id, required this.institutionName});

  factory IndependentTimetableProject.fromMap(String id, Map<String, dynamic> data) =>
      IndependentTimetableProject(id: id, institutionName: data['institutionName'] as String? ?? '');
}

/// One class within an independent project. `subjectTeacherNames` maps
/// subject -> a plain typed teacher NAME, not a real Firebase Auth uid —
/// there's no registered account behind it, since the whole point of
/// this feature is drafting a timetable for staff who aren't (and may
/// never be) real users of this app. That name is used directly as the
/// scheduling engine's opaque double-booking key server-side, so two
/// classes taught by "Mr. Banda" must spell his name identically for the
/// engine to know it's the same person — a real, disclosed limitation.
class IndependentTimetableClass {
  final String id;
  final String classGrade;
  final List<String> subjectNames;
  final Map<String, String> subjectTeacherNames;

  const IndependentTimetableClass({
    required this.id,
    required this.classGrade,
    required this.subjectNames,
    required this.subjectTeacherNames,
  });

  factory IndependentTimetableClass.fromMap(String id, Map<String, dynamic> data) => IndependentTimetableClass(
        id: id,
        classGrade: data['classGrade'] as String? ?? '',
        subjectNames: (data['subjectNames'] as List?)?.whereType<String>().toList() ?? const [],
        // Stored server-side under `subjectTeacherUids` (see
        // `saveIndependentTimetableClass` in index.ts) so the shared
        // `generateTimetableSchedule` engine needs zero changes — it just
        // reads an opaque subject->key map either way.
        subjectTeacherNames: (data['subjectTeacherUids'] as Map?)?.map((k, v) => MapEntry(k as String, v as String? ?? '')) ?? const {},
      );
}
