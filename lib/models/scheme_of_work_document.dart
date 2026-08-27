import 'scheme_of_work.dart';
import 'scheme_of_work_template.dart';

/// Once-per-document header fields for the CDC "Scheme of Work" template
/// (Ministry of Education / Name of School / Name of Teacher / Level /
/// Subject / Year), plus the "Curriculum Philosophy and Goals" block that
/// appears once at the top of real CDC scheme-of-work documents rather than
/// per week.
class SchemeOfWorkHeader {
  final String schoolName;
  final String teacherName;
  final String year;
  final String curriculumPhilosophyAndGoals;

  const SchemeOfWorkHeader({
    this.schoolName = '',
    this.teacherName = '',
    this.year = '',
    this.curriculumPhilosophyAndGoals = '',
  });

  SchemeOfWorkHeader copyWith({
    String? schoolName,
    String? teacherName,
    String? year,
    String? curriculumPhilosophyAndGoals,
  }) =>
      SchemeOfWorkHeader(
        schoolName: schoolName ?? this.schoolName,
        teacherName: teacherName ?? this.teacherName,
        year: year ?? this.year,
        curriculumPhilosophyAndGoals: curriculumPhilosophyAndGoals ?? this.curriculumPhilosophyAndGoals,
      );
}

const _weekWords = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen',
  'Nineteen', 'Twenty',
];

/// One row of the scheme-of-work table. Values for [SchemeOfWorkTemplate]'s
/// columns are keyed by column id rather than named fields, so the same row
/// type works for both the CBC and OBC templates (genuinely different
/// columns) without one growing fields the other doesn't use.
///
/// CBC and OBC group [SchemeOfWorkEntry] data into rows differently, matching
/// their real templates: CBC is one row per topic/sub-topic ([entries] has
/// exactly one), "Stage" numbering which lesson that is within its week.
/// OBC is one row per **week**, merging every topic/sub-topic taught that
/// week into shared cells ([entries] can have several) — see
/// [SchemeOfWorkDocumentDraft.fromEntries].
class SchemeOfWorkRowDraft {
  final List<SchemeOfWorkEntry> entries;

  /// Which lesson this is within its week (1, 2, 3, ...) — the CBC
  /// template's "Stage" column ("Lesson 3"). Unused for OBC.
  final int lessonNumber;

  /// True for OBC's "Week" column, which spells the number out ("One",
  /// "Two", ...) in the real template rather than using a numeral like CBC.
  final bool spellWeek;

  final Map<String, String> values;

  const SchemeOfWorkRowDraft({
    required this.entries,
    this.lessonNumber = 1,
    this.spellWeek = false,
    this.values = const {},
  });

  SchemeOfWorkEntry get primaryEntry => entries.first;

  factory SchemeOfWorkRowDraft.build(
    List<SchemeOfWorkEntry> entries, {
    required int lessonNumber,
    required bool spellWeek,
  }) {
    final values = <String, String>{};
    final competencies = entries.expand((e) => e.competencies).toList();
    if (competencies.isNotEmpty) {
      values['expectedStandards'] = '${competencies.first.description}, done correctly.';
    } else {
      final description = entries.first.subTopic?.description ?? entries.first.topic.description;
      if (description != null) values['expectedStandards'] = description;
    }
    return SchemeOfWorkRowDraft(entries: entries, lessonNumber: lessonNumber, spellWeek: spellWeek, values: values);
  }

  SchemeOfWorkRowDraft withValue(String columnId, String value) => SchemeOfWorkRowDraft(
        entries: entries,
        lessonNumber: lessonNumber,
        spellWeek: spellWeek,
        values: {...values, columnId: value},
      );

  /// Topic name(s) followed by any sub-topic names, deduped and in order —
  /// the OBC "Topic/Content" column, which merges a whole week's coverage
  /// into one cell rather than one topic per row like CBC.
  String get _topicContentBlock {
    final seenTopics = <String>{};
    final lines = <String>[];
    for (final entry in entries) {
      if (seenTopics.add(entry.topic.name)) lines.add(entry.topic.name.toUpperCase());
      if (entry.subTopic != null) lines.add(entry.subTopic!.name);
    }
    return lines.join('\n');
  }

  /// The cell text for [column] — computed directly from [entries] for
  /// auto-filled columns, otherwise whatever's in [values].
  String value(SchemeOfWorkColumnDef column) {
    switch (column.id) {
      case 'week':
        final week = primaryEntry.realWeekNumber ?? primaryEntry.weekNumber;
        return spellWeek && week < _weekWords.length ? _weekWords[week] : '$week';
      case 'stage':
        return 'Lesson $lessonNumber';
      case 'topic':
        return primaryEntry.topic.name;
      case 'subTopic':
        return primaryEntry.subTopic?.name ?? '';
      case 'topicSubTopic':
        return entries.map((e) => e.title).join('; ');
      case 'topicContent':
        return _topicContentBlock;
      case 'specificCompetence':
      case 'specificOutcomes':
        return entries.expand((e) => e.competencies).map((c) => c.description).join('\n');
      case 'learningActivities':
        return entries.expand((e) => e.objectives).map((o) => o.description).join('\n');
      default:
        return values[column.id] ?? '';
    }
  }
}

/// The full editable draft for one scheme-of-work document: one header plus
/// one row per generated [SchemeOfWorkEntry] (or, for OBC, per week — see
/// [SchemeOfWorkRowDraft]), built for a specific [SchemeOfWorkTemplate] (CBC
/// or OBC — see [schemeOfWorkTemplateFor]).
class SchemeOfWorkDocumentDraft {
  final SchemeOfWorkHeader header;
  final List<SchemeOfWorkRowDraft> rows;

  const SchemeOfWorkDocumentDraft({required this.header, required this.rows});

  /// Builds rows from [entries] (assumed already ordered by week), grouped
  /// to match each curriculum's real template structure.
  factory SchemeOfWorkDocumentDraft.fromEntries(List<SchemeOfWorkEntry> entries, {required String curriculumCode}) {
    final isCbc = curriculumCode.toUpperCase().contains('CBC');
    final rows = <SchemeOfWorkRowDraft>[];

    if (isCbc) {
      // One row per topic/sub-topic; "Stage" numbers which lesson this is
      // within its week.
      int? currentWeek;
      var lessonInWeek = 0;
      for (final entry in entries) {
        final week = entry.realWeekNumber ?? entry.weekNumber;
        lessonInWeek = (week == currentWeek) ? lessonInWeek + 1 : 1;
        currentWeek = week;
        rows.add(SchemeOfWorkRowDraft.build([entry], lessonNumber: lessonInWeek, spellWeek: false));
      }
    } else {
      // One row per week — every topic/sub-topic taught that week merges
      // into shared cells, matching the real OBC template.
      final byWeek = <int, List<SchemeOfWorkEntry>>{};
      final weekOrder = <int>[];
      for (final entry in entries) {
        final week = entry.realWeekNumber ?? entry.weekNumber;
        if (!byWeek.containsKey(week)) weekOrder.add(week);
        byWeek.putIfAbsent(week, () => []).add(entry);
      }
      for (final week in weekOrder) {
        rows.add(SchemeOfWorkRowDraft.build(byWeek[week]!, lessonNumber: 1, spellWeek: true));
      }
    }

    return SchemeOfWorkDocumentDraft(header: const SchemeOfWorkHeader(), rows: rows);
  }

  SchemeOfWorkDocumentDraft withHeader(SchemeOfWorkHeader header) =>
      SchemeOfWorkDocumentDraft(header: header, rows: rows);

  SchemeOfWorkDocumentDraft withRow(int index, SchemeOfWorkRowDraft row) {
    final updated = [...rows];
    updated[index] = row;
    return SchemeOfWorkDocumentDraft(header: header, rows: updated);
  }
}
