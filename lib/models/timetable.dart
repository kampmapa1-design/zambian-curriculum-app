/// Timetable Generation, Stage 1 (added 2026-09-14) — the school-wide
/// config Stage 4's (not yet built) scheduling engine will read.
/// `subjectDefaults` values are deliberately labelled "Suggested default"
/// everywhere they appear in the UI, never presented as an official
/// figure — these are editable starting points, not sourced curriculum
/// data. `practicalSubjectsExceptionList` seeds with only the two
/// examples the brief itself named (Food & Nutrition, Home Management) —
/// not expanded with any invented "official" list, per the standing
/// never-fabricate-data rule; a real school edits this to match its own
/// subject offering.
class TimetableConfig {
  final int periodsPerDay;
  final int periodLengthMinutes;
  final int teachingDaysPerWeek;
  final Map<String, int> subjectDefaults;
  final List<String> practicalSubjectsExceptionList;

  /// Stage 4's "maximum daily teaching load per teacher" — not named in
  /// Stage 1's own field list, added here since the scheduling engine
  /// genuinely needs it. Defaults to a sensible starting point (not
  /// periodsPerDay itself — a teacher teaching literally every period,
  /// every day, isn't a reasonable default), fully editable.
  final int maxDailyPeriodsPerTeacher;

  const TimetableConfig({
    required this.periodsPerDay,
    required this.periodLengthMinutes,
    required this.teachingDaysPerWeek,
    required this.subjectDefaults,
    required this.practicalSubjectsExceptionList,
    required this.maxDailyPeriodsPerTeacher,
  });

  factory TimetableConfig.empty() => const TimetableConfig(
        periodsPerDay: 8,
        periodLengthMinutes: 40,
        teachingDaysPerWeek: 5,
        subjectDefaults: {},
        practicalSubjectsExceptionList: ['Food & Nutrition', 'Home Management'],
        maxDailyPeriodsPerTeacher: 6,
      );

  factory TimetableConfig.fromMap(Map<String, dynamic> data) => TimetableConfig(
        periodsPerDay: (data['periodsPerDay'] as num?)?.toInt() ?? 8,
        periodLengthMinutes: (data['periodLengthMinutes'] as num?)?.toInt() ?? 40,
        teachingDaysPerWeek: (data['teachingDaysPerWeek'] as num?)?.toInt() ?? 5,
        subjectDefaults: (data['subjectDefaults'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toInt())) ?? const {},
        // Falls back to the same starting defaults as TimetableConfig.empty()
        // (not an empty list) — found by a real test (2026-09-14) exposing
        // that every OTHER field here already matched .empty()'s defaults
        // but this one silently didn't. In practice a saved config doc
        // always has a real value for this field (saveTimetableConfig
        // always writes it), so this only matters for a malformed/partial
        // document — but it should still behave the same way a brand-new
        // setup does, not silently clear the practical-subjects list.
        practicalSubjectsExceptionList: (data['practicalSubjectsExceptionList'] as List?)?.whereType<String>().toList() ??
            const ['Food & Nutrition', 'Home Management'],
        maxDailyPeriodsPerTeacher: (data['maxDailyPeriodsPerTeacher'] as num?)?.toInt() ?? (data['periodsPerDay'] as num?)?.toInt() ?? 6,
      );

  TimetableConfig copyWith({
    int? periodsPerDay,
    int? periodLengthMinutes,
    int? teachingDaysPerWeek,
    Map<String, int>? subjectDefaults,
    List<String>? practicalSubjectsExceptionList,
    int? maxDailyPeriodsPerTeacher,
  }) =>
      TimetableConfig(
        periodsPerDay: periodsPerDay ?? this.periodsPerDay,
        periodLengthMinutes: periodLengthMinutes ?? this.periodLengthMinutes,
        teachingDaysPerWeek: teachingDaysPerWeek ?? this.teachingDaysPerWeek,
        subjectDefaults: subjectDefaults ?? this.subjectDefaults,
        practicalSubjectsExceptionList: practicalSubjectsExceptionList ?? this.practicalSubjectsExceptionList,
        maxDailyPeriodsPerTeacher: maxDailyPeriodsPerTeacher ?? this.maxDailyPeriodsPerTeacher,
      );
}

/// One placed lesson — day/period are 0-indexed; the UI adds 1 for
/// display. Mirrors the `TimetableAssignment` shape `generateTimetable`
/// writes server-side (see index.ts).
class TimetableAssignment {
  final String classId;
  final String className;
  final String subjectName;
  final String teacherUid;
  final int day;
  final int period;

  /// Stage 7 — true once a human has moved or explicitly pinned this
  /// lesson; a locked assignment is never moved by a later "Regenerate".
  final bool locked;

  const TimetableAssignment({
    required this.classId,
    required this.className,
    required this.subjectName,
    required this.teacherUid,
    required this.day,
    required this.period,
    this.locked = false,
  });

  factory TimetableAssignment.fromMap(Map<String, dynamic> data) => TimetableAssignment(
        classId: data['classId'] as String? ?? '',
        className: data['className'] as String? ?? '',
        subjectName: data['subjectName'] as String? ?? '',
        teacherUid: data['teacherUid'] as String? ?? '',
        day: (data['day'] as num?)?.toInt() ?? 0,
        period: (data['period'] as num?)?.toInt() ?? 0,
        locked: data['locked'] as bool? ?? false,
      );
}

/// One specific, named reason the engine couldn't place something — see
/// `generateTimetableSchedule`'s own doc comment in index.ts for why this
/// exists instead of a silently-invalid schedule.
class TimetableConflict {
  final String description;
  final String? classId;
  final String? subjectName;
  final String? teacherUid;

  const TimetableConflict({required this.description, this.classId, this.subjectName, this.teacherUid});

  factory TimetableConflict.fromMap(Map<String, dynamic> data) => TimetableConflict(
        description: data['description'] as String? ?? '',
        classId: data['classId'] as String?,
        subjectName: data['subjectName'] as String?,
        teacherUid: data['teacherUid'] as String?,
      );
}

/// Stage 6 — a plain-language gloss on ONE [TimetableConflict], keyed by
/// its position in that same list. The AI only ever explains/suggests
/// here; whether something IS a conflict was already decided by the
/// deterministic engine before this ever runs (see
/// `explainTimetableConflicts` in index.ts).
class TimetableConflictExplanation {
  final int conflictIndex;
  final String explanation;
  final String suggestedFix;

  const TimetableConflictExplanation({required this.conflictIndex, required this.explanation, required this.suggestedFix});

  factory TimetableConflictExplanation.fromMap(Map<String, dynamic> data) => TimetableConflictExplanation(
        conflictIndex: (data['conflictIndex'] as num?)?.toInt() ?? -1,
        explanation: data['explanation'] as String? ?? '',
        suggestedFix: data['suggestedFix'] as String? ?? '',
      );
}

/// Stage 3 — the result of `parseTimetableConstraint`: Gemini's read of a
/// typed instruction, plus the real member/class it matched against (or
/// null if nothing matched confidently). This is a PROPOSAL only — see
/// index.ts's module comment on `parseTimetableConstraint` for why
/// nothing gets applied until a human confirms it in the UI and a
/// separate call (`setTeacherAvailability` or the existing
/// `assignSubjectTeacher`) actually writes it.
class ParsedTimetableConstraint {
  final String kind; // 'availability' | 'assignment' | 'unrecognized'
  final String teacherName;
  final String? teacherUid;
  final String subjectName;
  final String className;
  final String? classId;
  final String constraintType; // 'unavailable' | 'available_only' | ''
  final List<String> daysOfWeek;
  final String timeOfDay; // 'morning' | 'afternoon' | 'all_day'
  final String summary;
  final List<String> unavailableSlots;

  const ParsedTimetableConstraint({
    required this.kind,
    required this.teacherName,
    required this.teacherUid,
    required this.subjectName,
    required this.className,
    required this.classId,
    required this.constraintType,
    required this.daysOfWeek,
    required this.timeOfDay,
    required this.summary,
    required this.unavailableSlots,
  });

  factory ParsedTimetableConstraint.fromMap(Map<String, dynamic> data) => ParsedTimetableConstraint(
        kind: data['kind'] as String? ?? 'unrecognized',
        teacherName: data['teacherName'] as String? ?? '',
        teacherUid: data['teacherUid'] as String?,
        subjectName: data['subjectName'] as String? ?? '',
        className: data['className'] as String? ?? '',
        classId: data['classId'] as String?,
        constraintType: data['constraintType'] as String? ?? '',
        daysOfWeek: (data['daysOfWeek'] as List?)?.whereType<String>().toList() ?? const [],
        timeOfDay: data['timeOfDay'] as String? ?? 'all_day',
        summary: data['summary'] as String? ?? '',
        unavailableSlots: (data['unavailableSlots'] as List?)?.whereType<String>().toList() ?? const [],
      );
}

/// Stage 2 — one subject row read off a photographed paper timetable,
/// via `extractTimetableFromPhoto`. `teacherUid` is only set when the
/// server matched `teacherName` exactly against a real school member;
/// a null match is shown to the operator to resolve by hand rather than
/// guessed.
class ExtractedTimetableSubject {
  final String name;
  final int periodsPerWeek;
  final String teacherName;
  final String? teacherUid;

  const ExtractedTimetableSubject({required this.name, required this.periodsPerWeek, required this.teacherName, required this.teacherUid});

  factory ExtractedTimetableSubject.fromMap(Map<String, dynamic> data) => ExtractedTimetableSubject(
        name: data['name'] as String? ?? '',
        periodsPerWeek: (data['periodsPerWeek'] as num?)?.toInt() ?? 0,
        teacherName: data['teacherName'] as String? ?? '',
        teacherUid: data['teacherUid'] as String?,
      );
}

/// Stage 2 — the full result of reading a photographed paper timetable.
/// Read-only, like [ParsedTimetableConstraint]: nothing is applied until
/// the operator reviews this on screen and confirms.
class ExtractedTimetable {
  final int periodsPerDay;
  final int periodLengthMinutes;
  final int teachingDaysPerWeek;
  final List<ExtractedTimetableSubject> subjects;
  final String notes;

  const ExtractedTimetable({
    required this.periodsPerDay,
    required this.periodLengthMinutes,
    required this.teachingDaysPerWeek,
    required this.subjects,
    required this.notes,
  });

  factory ExtractedTimetable.fromMap(Map<String, dynamic> data) => ExtractedTimetable(
        periodsPerDay: (data['periodsPerDay'] as num?)?.toInt() ?? 0,
        periodLengthMinutes: (data['periodLengthMinutes'] as num?)?.toInt() ?? 0,
        teachingDaysPerWeek: (data['teachingDaysPerWeek'] as num?)?.toInt() ?? 0,
        subjects: (data['subjects'] as List?)?.map((s) => ExtractedTimetableSubject.fromMap((s as Map).cast<String, dynamic>())).toList() ?? const [],
        notes: data['notes'] as String? ?? '',
      );
}

class GeneratedTimetable {
  final List<TimetableAssignment> assignments;
  final List<TimetableConflict> conflicts;
  final List<TimetableConflictExplanation> conflictExplanations;

  const GeneratedTimetable({required this.assignments, required this.conflicts, required this.conflictExplanations});

  factory GeneratedTimetable.fromMap(Map<String, dynamic> data) => GeneratedTimetable(
        assignments: (data['assignments'] as List?)?.map((a) => TimetableAssignment.fromMap((a as Map).cast<String, dynamic>())).toList() ?? const [],
        conflicts: (data['conflicts'] as List?)?.map((c) => TimetableConflict.fromMap((c as Map).cast<String, dynamic>())).toList() ?? const [],
        conflictExplanations: (data['conflictExplanations'] as List?)
                ?.map((e) => TimetableConflictExplanation.fromMap((e as Map).cast<String, dynamic>()))
                .toList() ??
            const [],
      );
}
