import 'lesson_history_entry.dart';

enum RecordOfWorkColumnType { text, multiline, date, number }

/// One column of a Record of Work document. Templates are data (see
/// [defaultRecordOfWorkTemplate]), not hardcoded UI — correcting a label,
/// reordering columns, or adding a new one means editing this file's
/// default (or, later, a teacher-editable config), not rebuilding screens.
class RecordOfWorkColumnDef {
  final String id;
  final String label;
  final RecordOfWorkColumnType type;

  /// True for columns the app fills in itself from the pulled lesson
  /// history (date, class, subject, topic) — not editable per-row.
  final bool autoFilled;

  /// True for columns left blank for the teacher to fill in by hand or on
  /// the printed page (periods, remarks, attendance, signatures).
  final bool manualEntry;

  const RecordOfWorkColumnDef({
    required this.id,
    required this.label,
    required this.type,
    this.autoFilled = false,
    this.manualEntry = false,
  });
}

/// A Record of Work template: its column definitions plus a configurable
/// list of standard remarks a teacher can pick from instead of retyping a
/// common comment every row.
class RecordOfWorkTemplate {
  final String id;
  final String name;
  final String source;
  final List<RecordOfWorkColumnDef> columns;
  final List<String> standardRemarks;

  const RecordOfWorkTemplate({
    required this.id,
    required this.name,
    required this.source,
    required this.columns,
    this.standardRemarks = const [],
  });

  Iterable<RecordOfWorkColumnDef> get manualColumns => columns.where((c) => c.manualEntry);
}

/// A standard Zambian school Record of Work layout — Date/Class/Subject/
/// Topic auto-filled from the app's own lesson history, Periods/Remarks/
/// Attendance/Signatures left for the teacher to complete. Unlike the
/// lesson plan templates, this wasn't cross-checked against a real
/// submitted sample document — replace `columns`/`standardRemarks` here (or
/// build a teacher-facing editor around this same config) once a real one
/// is available.
const defaultRecordOfWorkTemplate = RecordOfWorkTemplate(
  id: 'record_of_work_v1',
  name: 'Record of Work',
  source: 'Standard Zambian school Record of Work layout (Date / Class / Subject / Topic covered / '
      'No. of Periods / Remarks / Attendance / Teacher\'s Signature / HOD\'s Signature) — configurable, '
      'not yet cross-checked against a real submitted sample the way the lesson plan templates were.',
  columns: [
    RecordOfWorkColumnDef(id: 'date', label: 'Date', type: RecordOfWorkColumnType.date, autoFilled: true),
    RecordOfWorkColumnDef(id: 'className', label: 'Class', type: RecordOfWorkColumnType.text, autoFilled: true),
    RecordOfWorkColumnDef(id: 'subjectName', label: 'Subject', type: RecordOfWorkColumnType.text, autoFilled: true),
    RecordOfWorkColumnDef(
        id: 'topicLabel', label: 'Topic / Sub-topic Covered', type: RecordOfWorkColumnType.text, autoFilled: true),
    RecordOfWorkColumnDef(id: 'periods', label: 'No. of Periods', type: RecordOfWorkColumnType.number, manualEntry: true),
    RecordOfWorkColumnDef(id: 'remarks', label: 'Remarks', type: RecordOfWorkColumnType.multiline, manualEntry: true),
    RecordOfWorkColumnDef(id: 'attendance', label: 'Attendance', type: RecordOfWorkColumnType.text, manualEntry: true),
    RecordOfWorkColumnDef(
        id: 'teacherSignature', label: "Teacher's Signature", type: RecordOfWorkColumnType.text, manualEntry: true),
    RecordOfWorkColumnDef(
        id: 'hodSignature', label: "HOD's Signature / Comment", type: RecordOfWorkColumnType.text, manualEntry: true),
  ],
  standardRemarks: [
    'Work covered as planned',
    'Topic partially covered — continue next lesson',
    'Lesson postponed',
    'Revision/consolidation lesson',
  ],
);

/// One row of a generated Record of Work — the auto-filled part comes
/// straight from a [LessonHistoryEntry]; [manualValues] holds whatever the
/// teacher has typed for the template's manual-entry columns (keyed by
/// [RecordOfWorkColumnDef.id]), starting empty.
class RecordOfWorkRow {
  final DateTime date;
  final String className;
  final String subjectName;
  final String topicLabel;
  final Map<String, String> manualValues;

  const RecordOfWorkRow({
    required this.date,
    required this.className,
    required this.subjectName,
    required this.topicLabel,
    this.manualValues = const {},
  });

  factory RecordOfWorkRow.fromLessonHistory(LessonHistoryEntry entry) => RecordOfWorkRow(
        date: entry.date,
        className: entry.gradeName,
        subjectName: entry.subjectName,
        topicLabel: entry.topicLabel,
      );

  RecordOfWorkRow withManualValue(String columnId, String value) =>
      RecordOfWorkRow(
        date: date,
        className: className,
        subjectName: subjectName,
        topicLabel: topicLabel,
        manualValues: {...manualValues, columnId: value},
      );

  String value(RecordOfWorkColumnDef column) {
    if (column.id == 'date') {
      return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
    }
    if (column.id == 'className') return className;
    if (column.id == 'subjectName') return subjectName;
    if (column.id == 'topicLabel') return topicLabel;
    return manualValues[column.id] ?? '';
  }
}

enum RecordOfWorkStatus { pending, approved, needsRevision }

extension RecordOfWorkStatusLabel on RecordOfWorkStatus {
  String get label => switch (this) {
        RecordOfWorkStatus.pending => 'Pending',
        RecordOfWorkStatus.approved => 'Approved',
        RecordOfWorkStatus.needsRevision => 'Needs Revision',
      };
}

/// One period the Record of Work covers — Weekly or Fortnightly, matching
/// what the teacher picked when generating it.
enum RecordOfWorkPeriod { weekly, fortnightly }

extension RecordOfWorkPeriodLabel on RecordOfWorkPeriod {
  String get label => switch (this) {
        RecordOfWorkPeriod.weekly => 'Weekly',
        RecordOfWorkPeriod.fortnightly => 'Fortnightly',
      };

  Duration get duration => switch (this) {
        RecordOfWorkPeriod.weekly => const Duration(days: 6),
        RecordOfWorkPeriod.fortnightly => const Duration(days: 13),
      };
}

/// A generated Record of Work, ready for review/export. [status] is a
/// forward-looking field (Stage 5) for a digital HOD sign-off flow that
/// doesn't exist yet — defaults to 'Pending' and is otherwise inert today.
class RecordOfWorkDraft {
  final String schoolName;
  final String teacherName;
  final String curriculumName;
  final String subjectName;
  final String className;
  final RecordOfWorkPeriod period;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final RecordOfWorkStatus status;
  final List<RecordOfWorkRow> rows;

  const RecordOfWorkDraft({
    this.schoolName = '',
    this.teacherName = '',
    required this.curriculumName,
    required this.subjectName,
    required this.className,
    required this.period,
    required this.rangeStart,
    required this.rangeEnd,
    this.status = RecordOfWorkStatus.pending,
    required this.rows,
  });

  RecordOfWorkDraft copyWith({
    String? schoolName,
    String? teacherName,
    RecordOfWorkStatus? status,
    List<RecordOfWorkRow>? rows,
  }) =>
      RecordOfWorkDraft(
        schoolName: schoolName ?? this.schoolName,
        teacherName: teacherName ?? this.teacherName,
        curriculumName: curriculumName,
        subjectName: subjectName,
        className: className,
        period: period,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        status: status ?? this.status,
        rows: rows ?? this.rows,
      );
}
