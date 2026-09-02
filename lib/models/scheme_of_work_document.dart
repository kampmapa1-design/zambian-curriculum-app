import '../services/scheme_of_work_calendar_pacing.dart';
import '../services/scheme_of_work_suggestions.dart';
import 'scheme_of_work.dart';
import 'scheme_of_work_template.dart';
import 'zambian_term_calendar.dart';

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

  final Map<String, String> values;

  /// Set only for a synthetic row with no real topic behind it — the
  /// Mid-Term Break week the calendar-pacing engine inserts explicitly
  /// (see SchemeOfWorkCalendarPacing) rather than silently skipping.
  /// [entries] is empty for such a row; [overrideWeekNumber] supplies the
  /// week number that would otherwise come from an entry.
  final String? specialRowLabel;
  final int? overrideWeekNumber;

  /// The week number actually shown to the reader in the "Week" column —
  /// always a clean, incrementing count (1, 2, 3, ...) matching this row's
  /// own position in the final document, set once by
  /// [SchemeOfWorkDocumentDraft.fromEntries] after every row (including the
  /// synthetic Mid-Term Break/End-of-Term rows) is in its final order.
  /// Deliberately NOT the same as any entry's own sourced `realWeekNumber`
  /// or [overrideWeekNumber]/[SchemeOfWorkEntry.weekNumber] — those still
  /// drive row ORDER (see `weekOf` in `_insertSpecialWeekRow`) and which
  /// entries share a row, but a generated scheme can legitimately continue
  /// past where a previous term's own scheme left off (see
  /// ClassResumePickerScreen), and a topic carried over from a different
  /// original term has a real week number that means nothing on THIS
  /// document's own calendar — showing it verbatim produced a real, reported
  /// "week 7...13, then week 1...3" disordered document. A generated scheme
  /// is always read top-to-bottom as this term's own Week 1 through its
  /// last week, never as a patchwork of other terms' original numbering.
  final int displayWeekNumber;

  const SchemeOfWorkRowDraft({
    required this.entries,
    this.lessonNumber = 1,
    this.values = const {},
    this.specialRowLabel,
    this.overrideWeekNumber,
    this.displayWeekNumber = 1,
  });

  factory SchemeOfWorkRowDraft.special({
    required String label,
    required int weekNumber,
  }) =>
      SchemeOfWorkRowDraft(
        entries: const [],
        specialRowLabel: label,
        overrideWeekNumber: weekNumber,
      );

  SchemeOfWorkEntry get primaryEntry => entries.first;

  factory SchemeOfWorkRowDraft.build(
    List<SchemeOfWorkEntry> entries, {
    required int lessonNumber,
    String? curriculumCode,
    String? subjectName,
  }) {
    final values = <String, String>{};
    final competencies = entries.expand((e) => e.competencies).toList();
    if (competencies.isNotEmpty) {
      values['expectedStandards'] = '${competencies.first.description}, done correctly.';
    } else {
      final description = entries.first.subTopic?.description ?? entries.first.topic.description;
      if (description != null) values['expectedStandards'] = description;
    }

    // References: real sourced values (from a genuine scheme of work — see
    // SubTopic.references) whenever any entry on this row has one, merged
    // if several entries genuinely differ. When nothing was ever sourced,
    // fall back to naming the syllabus itself — always true and never
    // fabricated, unlike inventing a specific textbook title/citation with
    // no real source behind it (see feedback-sourcing-rules). This means
    // References is never blank on a generated scheme, but a fallback
    // citation is visually distinguishable from a real one by content, not
    // by any special formatting — it's still real, just less specific.
    final realReferences = entries.map((e) => e.references).whereType<String>().toSet();
    if (realReferences.isNotEmpty) {
      values['references'] = realReferences.join('; ');
    } else if (subjectName != null && curriculumCode != null) {
      values['references'] = '$subjectName Syllabus ($curriculumCode)';
    }

    // Key Competences / Strategies & Methodologies / TL Aids & Materials
    // have no source data anywhere in this app's bundled syllabi — these
    // three columns were previously left completely blank on every
    // generated scheme. Rule-based, always-editable starting suggestions
    // now fill them, grounded in the topic's own text — see
    // scheme_of_work_suggestions.dart for what these are and, importantly,
    // what they deliberately are NOT (not a claim of official CDC wording).
    final combinedText = [
      entries.first.topic.name,
      entries.first.subTopic?.name ?? '',
      entries.first.topic.description ?? '',
      entries.first.subTopic?.description ?? '',
      ...entries.expand((e) => e.competencies).map((c) => c.description),
      ...entries.expand((e) => e.objectives).map((o) => o.description),
    ].join(' ');
    values['keyCompetences'] = suggestKeyCompetences(combinedText);
    values['strategiesMethodologies'] = suggestStrategiesMethodologies(combinedText);
    values['tlAidsMaterials'] = suggestTlAidsMaterials(combinedText);
    // OBC's simpler template uses different column ids for the same kind
    // of content — same suggestions, just filed under 'methods'/'resources'.
    values['methods'] = suggestStrategiesMethodologies(combinedText);
    values['resources'] = suggestTlAidsMaterials(combinedText);

    return SchemeOfWorkRowDraft(entries: entries, lessonNumber: lessonNumber, values: values);
  }

  // Real crash fixed here (2026-08-31): this used to omit specialRowLabel/
  // overrideWeekNumber entirely, so calling this on the synthetic Mid-Term
  // Break/End-of-Term row (see SchemeOfWorkDocumentDraft — entries is
  // deliberately empty for those) silently turned it into what LOOKED
  // like a regular row with zero entries. scheme_of_work_document_screen
  // .dart calls this on every row (including special ones) whenever a
  // teacher edits a manual column OR shares the document
  // (_syncDraftFromControllers runs before every export) — the very next
  // rebuild then tried `primaryEntry` (`entries.first`) on that now-
  // unmarked empty row and threw "Bad state: No element". Every field
  // must be carried forward here, not just the ones this method means to
  // change.
  SchemeOfWorkRowDraft withValue(String columnId, String value) => SchemeOfWorkRowDraft(
        entries: entries,
        lessonNumber: lessonNumber,
        values: {...values, columnId: value},
        specialRowLabel: specialRowLabel,
        overrideWeekNumber: overrideWeekNumber,
        displayWeekNumber: displayWeekNumber,
      );

  /// Set once by [SchemeOfWorkDocumentDraft.fromEntries] after every row is
  /// in its final order — see [displayWeekNumber]'s own doc comment.
  SchemeOfWorkRowDraft withDisplayWeekNumber(int weekNumber) => SchemeOfWorkRowDraft(
        entries: entries,
        lessonNumber: lessonNumber,
        values: values,
        specialRowLabel: specialRowLabel,
        overrideWeekNumber: overrideWeekNumber,
        displayWeekNumber: weekNumber,
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
    if (specialRowLabel case final label?) {
      if (column.id == 'week') return '$displayWeekNumber';
      const labelColumns = {'topic', 'topicContent', 'subTopic', 'topicSubTopic', 'specificCompetence', 'specificOutcomes'};
      return labelColumns.contains(column.id) ? label : '';
    }
    switch (column.id) {
      case 'week':
        return '$displayWeekNumber';
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
        final objectives = entries.expand((e) => e.objectives).map((o) => o.description).join('\n');
        if (objectives.isNotEmpty) return objectives;
        // Real syllabus content has learning_objectives populated for only
        // some subjects/topics (verified 2026-08-29: ~57% of sub-topics
        // across bundled CBC syllabi) — previously this column just went
        // blank for the rest, which was a real contributor to schemes
        // looking mostly empty. Falls back to the topic/sub-topic's own
        // description, which is populated almost everywhere.
        return entries.first.subTopic?.description ?? entries.first.topic.description ?? '';
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
  ///
  /// Real fixes applied here, all grounded in verified Zambian Ministry of
  /// Education calendar data (2026-08-29 — see zambian_term_calendar.dart):
  /// [applyCalendarPacing] stretches real topics across the term's real 12
  /// teaching weeks when the syllabus data has no real per-topic week
  /// numbers of its own (previously produced schemes covering only as many
  /// weeks as there were topics — e.g. 6 of 13, a real reported bug), and
  /// an explicit "Mid-Term Break" row is always inserted at week 7 —
  /// confirmed by both the formula AND real sourced data
  /// (civic_education_form2's own real week numbers skip week 7 in every
  /// term) to be a stable structural fact of the real calendar, not
  /// something to silently omit.
  ///
  /// [applyCalendarPacing]'s real/paced week numbers still decide row
  /// ORDER and where the synthetic rows land, but every row's own
  /// DISPLAYED week number (see [SchemeOfWorkRowDraft.displayWeekNumber])
  /// is reassigned as a final pass, purely by each row's position in the
  /// finished list — a real, reported bug (2026-09-02): a scheme that
  /// continues past where a previous term's own scheme left off (see
  /// ClassResumePickerScreen) mixes topics originally filed under
  /// different terms, each still carrying ITS OWN original term's real
  /// week number — showing those verbatim produced a genuinely disordered
  /// document ("week 7...13, then week 1...3"). This document is always
  /// read as its own clean Week 1 through its last week.
  factory SchemeOfWorkDocumentDraft.fromEntries(
    List<SchemeOfWorkEntry> entries, {
    required String curriculumCode,
    String? subjectName,
  }) {
    final isCbc = curriculumCode.toUpperCase().contains('CBC');
    final pacedEntries = applyCalendarPacing(entries);
    final rows = <SchemeOfWorkRowDraft>[];

    if (isCbc) {
      // One row per topic/sub-topic; "Stage" numbers which lesson this is
      // within its week.
      int? currentWeek;
      var lessonInWeek = 0;
      for (final entry in pacedEntries) {
        final week = entry.realWeekNumber ?? entry.weekNumber;
        lessonInWeek = (week == currentWeek) ? lessonInWeek + 1 : 1;
        currentWeek = week;
        rows.add(SchemeOfWorkRowDraft.build(
          [entry],
          lessonNumber: lessonInWeek,
          curriculumCode: curriculumCode,
          subjectName: subjectName,
        ));
      }
      _insertMidtermBreakRow(rows);
      _insertEndOfTermRow(rows);
    } else {
      // One row per week — every topic/sub-topic taught that week merges
      // into shared cells, matching the real OBC template.
      final byWeek = <int, List<SchemeOfWorkEntry>>{};
      final weekOrder = <int>[];
      for (final entry in pacedEntries) {
        final week = entry.realWeekNumber ?? entry.weekNumber;
        if (!byWeek.containsKey(week)) weekOrder.add(week);
        byWeek.putIfAbsent(week, () => []).add(entry);
      }
      for (final week in weekOrder) {
        rows.add(SchemeOfWorkRowDraft.build(
          byWeek[week]!,
          lessonNumber: 1,
          curriculumCode: curriculumCode,
          subjectName: subjectName,
        ));
      }
      _insertMidtermBreakRow(rows);
      _insertEndOfTermRow(rows);
    }

    final renumbered = [for (var i = 0; i < rows.length; i++) rows[i].withDisplayWeekNumber(i + 1)];
    return SchemeOfWorkDocumentDraft(header: const SchemeOfWorkHeader(), rows: renumbered);
  }

  /// Inserts a synthetic "Mid-Term Break" row at week 7's position in
  /// [rows] (already in week order), unless a row for week 7 genuinely
  /// already exists (a subject whose real sourced data puts something
  /// else there — trust the real data over this assumption).
  static void _insertMidtermBreakRow(List<SchemeOfWorkRowDraft> rows) =>
      _insertSpecialWeekRow(rows, week: TermDates.midtermBreakWeek, label: 'MID-TERM BREAK');

  /// Inserts a synthetic "End of Term Examinations" row at the term's
  /// final week (13), unless real sourced data already occupies that week
  /// — same trust-real-data-first rule as the mid-term row. Added
  /// 2026-08-31 after a real report of generated schemes scheduling new
  /// teaching content into week 13 instead of the exam week every real
  /// sourced scheme checked this project has ingested actually reserves
  /// there — see [TermDates.endOfTermWeek]'s own doc for why this isn't
  /// guesswork.
  static void _insertEndOfTermRow(List<SchemeOfWorkRowDraft> rows) => _insertSpecialWeekRow(
        rows,
        week: TermDates.endOfTermWeek,
        label: 'END OF TERM EXAMINATIONS',
      );

  static void _insertSpecialWeekRow(
    List<SchemeOfWorkRowDraft> rows, {
    required int week,
    required String label,
  }) {
    int weekOf(SchemeOfWorkRowDraft r) => r.overrideWeekNumber ?? r.primaryEntry.realWeekNumber ?? r.primaryEntry.weekNumber;
    if (rows.any((r) => weekOf(r) == week)) return;
    final insertAt = rows.indexWhere((r) => weekOf(r) > week);
    final row = SchemeOfWorkRowDraft.special(label: label, weekNumber: week);
    if (insertAt == -1) {
      rows.add(row);
    } else {
      rows.insert(insertAt, row);
    }
  }

  SchemeOfWorkDocumentDraft withHeader(SchemeOfWorkHeader header) =>
      SchemeOfWorkDocumentDraft(header: header, rows: rows);

  SchemeOfWorkDocumentDraft withRow(int index, SchemeOfWorkRowDraft row) {
    final updated = [...rows];
    updated[index] = row;
    return SchemeOfWorkDocumentDraft(header: header, rows: updated);
  }
}
