import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/scheme_of_work.dart';
import '../models/scheme_of_work_document.dart';
import '../models/scheme_of_work_template.dart';
import '../models/syllabus_models.dart';
import '../models/zambian_term_calendar.dart';
import '../services/class_progress_repository.dart';
import '../services/lesson_history_repository.dart';
import '../services/scheme_of_work_ai_content_service.dart';
import '../services/scheme_of_work_document_service.dart';
import '../services/subject_content_index.dart';
import '../services/syllabus_document_service.dart';

/// Lets a teacher fill in whichever scheme-of-work columns aren't part of
/// the app's syllabus data — which columns those are depends on the
/// curriculum's real template (see scheme_of_work_template.dart: CBC and
/// OBC have genuinely different columns) — then export the whole generated
/// scheme as PDF or Word and share it, entirely on-device.
class SchemeOfWorkDocumentScreen extends StatefulWidget {
  const SchemeOfWorkDocumentScreen({
    super.key,
    required this.template,
    required this.entries,
    this.classLabel,
    this.targetTerm,
    this.documentService,
  });

  final SyllabusTemplate template;
  final List<SchemeOfWorkEntry> entries;

  /// Which named class this generated scheme is for — see
  /// ClassResumePickerScreen/ClassProgressRepository. Every "mark taught"
  /// and the automatic post-export progress update (see [_export]) write
  /// to this specific class's own cursor, never any other class's. Null
  /// for a scheme with no real class attached (2026-09-04 — "Topics in
  /// the Scheme" builds one starting from a teacher-picked topic rather
  /// than a real class's tracked position) — [_markTaught]/[_export]
  /// simply skip the progress write in that case, same "a one-off scheme
  /// must never corrupt a real class's progress record" principle the
  /// resume flow was already built on.
  final String? classLabel;

  /// The term the teacher picked this scheme's real calendar dates for
  /// (see [_realCalendarNote]) — distinct from which topics actually end
  /// up in [entries], since coverage (not the picked term's own original
  /// topic list) drives that. Null only for a caller with no term context
  /// at all, in which case the calendar note is simply omitted.
  final Term? targetTerm;

  final SchemeOfWorkDocumentService? documentService;

  @override
  State<SchemeOfWorkDocumentScreen> createState() => _SchemeOfWorkDocumentScreenState();
}

class _SchemeOfWorkDocumentScreenState extends State<SchemeOfWorkDocumentScreen> {
  late final SchemeOfWorkDocumentService _documentService =
      widget.documentService ?? SchemeOfWorkDocumentService();
  late final SchemeOfWorkTemplate _activeTemplate = schemeOfWorkTemplateFor(widget.template.curriculum.code);
  late SchemeOfWorkDocumentDraft _draft;
  final Map<String, TextEditingController> _controllers = {};
  final LessonHistoryRepository _lessonHistoryRepository = LessonHistoryRepository();
  final _syllabusDocumentService = SyllabusDocumentService();
  final _classProgressRepository = ClassProgressRepository();
  final SubjectContentIndex _contentIndex = SubjectContentIndex();
  final _aiContentService = SchemeOfWorkAiContentService();
  bool _exporting = false;
  bool _sharingSyllabus = false;
  bool _enrichingAi = false;
  final Set<int> _markedTaughtTopicIds = {};
  List<MarkingScheme> _relatedMarkingKeys = const [];

  Iterable<SchemeOfWorkColumnDef> get _manualColumns => _activeTemplate.columns.where((c) => c.manualEntry);

  /// [_manualColumns] plus, for this specific row, whichever normally-
  /// auto-filled columns AI enrichment (see [_enrichThinRows]) filled in —
  /// AI-generated content is never treated as locked source-of-truth the
  /// way real sourced syllabus data is, so it gets the same editable
  /// treatment as any other suggested column.
  Iterable<SchemeOfWorkColumnDef> _editableColumnsFor(SchemeOfWorkRowDraft row) {
    final manualIds = _manualColumns.map((c) => c.id).toSet();
    return [
      ..._manualColumns,
      for (final id in row.aiEnrichedColumnIds)
        if (!manualIds.contains(id))
          for (final c in _activeTemplate.columns)
            if (c.id == id) c,
    ];
  }

  @override
  void initState() {
    super.initState();
    _draft = SchemeOfWorkDocumentDraft.fromEntries(
      widget.entries,
      curriculumCode: widget.template.curriculum.code,
      subjectName: widget.template.subject.name,
    );

    _controllers['schoolName'] = TextEditingController(text: _draft.header.schoolName);
    _controllers['teacherName'] = TextEditingController(text: _draft.header.teacherName);
    // Defaults to the current year rather than staying blank — needed to
    // compute the real calendar dates shown in the header (see
    // _realCalendarNote), and still fully editable for planning a future
    // year's scheme ahead of time.
    _controllers['year'] = TextEditingController(text: _draft.header.year.isEmpty ? '${DateTime.now().year}' : _draft.header.year);
    _controllers['philosophy'] = TextEditingController(text: _draft.header.curriculumPhilosophyAndGoals);
    _controllers['year']!.addListener(() => setState(() {}));

    for (var i = 0; i < _draft.rows.length; i++) {
      final row = _draft.rows[i];
      for (final column in _manualColumns) {
        _controllers['row_${i}_${column.id}'] = TextEditingController(text: row.value(column));
      }
    }
    _loadRelatedMarkingKeys();
    _enrichThinRows();
  }

  /// Fills real, common gaps left by [SchemeOfWorkDocumentDraft.fromEntries]
  /// — a genuine bundled-syllabus topic with no real Specific Competence/
  /// Outcome or Learning Activities content sourced for it yet — using AI
  /// grounded in that topic's own real name/description, per this app's
  /// standing rule: real sourced content always wins first, AI only ever
  /// covers what's genuinely still empty after that. See
  /// SchemeOfWorkAiContentService's own doc comment — this is silent and
  /// best-effort (offline or any failure just leaves today's existing
  /// fallback in place) and batched into one call for the whole document,
  /// never one call per row.
  Future<void> _enrichThinRows() async {
    final thin = <int, ThinSchemeOfWorkRow>{};
    for (var i = 0; i < _draft.rows.length; i++) {
      final row = _draft.rows[i];
      if (!row.needsSpecificCompetence && !row.needsLearningActivities) continue;
      if (row.entries.isEmpty) continue;
      final entry = row.primaryEntry;
      thin[i] = ThinSchemeOfWorkRow(
        id: '$i',
        topicName: entry.topic.name,
        subTopicName: entry.subTopic?.name,
        existingDescription: entry.subTopic?.description ?? entry.topic.description,
        needsSpecificCompetence: row.needsSpecificCompetence,
        needsLearningActivities: row.needsLearningActivities,
      );
    }
    if (thin.isEmpty) return;

    if (mounted) setState(() => _enrichingAi = true);
    final results = await _aiContentService.generate(
      rows: thin.values.toList(),
      subjectName: widget.template.subject.name,
      gradeName: widget.template.grade.name,
      curriculumName: widget.template.curriculum.name,
    );
    if (!mounted) return;
    setState(() {
      _enrichingAi = false;
      for (final MapEntry(key: rowIndex, value: request) in thin.entries) {
        final content = results[request.id];
        if (content == null) continue;
        final enriched = _draft.rows[rowIndex].withAiEnrichment(
          specificCompetence: content.specificCompetence,
          learningActivities: content.learningActivities,
        );
        _draft = _draft.withRow(rowIndex, enriched);
        for (final columnId in enriched.aiEnrichedColumnIds) {
          final key = 'row_${rowIndex}_$columnId';
          if (_controllers.containsKey(key)) continue;
          for (final column in _activeTemplate.columns) {
            if (column.id == columnId) {
              _controllers[key] = TextEditingController(text: enriched.value(column));
              break;
            }
          }
        }
      }
    });
  }

  /// Marking keys uploaded through AI-Assisted Marking, for this same
  /// subject — appended to the exported scheme as a real "Reference:
  /// Assessment Content" section, entirely offline. See the identical
  /// pattern/reasoning in lesson_plan_screen.dart.
  Future<void> _loadRelatedMarkingKeys() async {
    final matches = await _contentIndex.relatedMarkingKeys(widget.template.subject.name);
    if (mounted && matches.isNotEmpty) setState(() => _relatedMarkingKeys = matches);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncDraftFromControllers() {
    _draft = _draft.withHeader(SchemeOfWorkHeader(
      schoolName: _controllers['schoolName']!.text,
      teacherName: _controllers['teacherName']!.text,
      year: _controllers['year']!.text,
      curriculumPhilosophyAndGoals: _controllers['philosophy']!.text,
    ));
    for (var i = 0; i < _draft.rows.length; i++) {
      var row = _draft.rows[i];
      for (final column in _editableColumnsFor(row)) {
        final controller = _controllers['row_${i}_${column.id}'];
        if (controller == null) continue;
        row = row.withValue(column.id, controller.text);
      }
      _draft = _draft.withRow(i, row);
    }
  }

  SchemeOfWorkDocumentContext get _context => SchemeOfWorkDocumentContext(
        subjectName: widget.template.subject.name,
        gradeName: widget.template.grade.name,
        curriculumName: widget.template.curriculum.name,
        curriculumCode: widget.template.curriculum.code,
        termLabel: widget.targetTerm?.name ?? '',
        realCalendarNote: _realCalendarNote(),
      );

  /// The real Ministry of Education term calendar for whatever year is
  /// entered in the header, shown alongside the generated scheme so a
  /// teacher can see exactly which real dates each week corresponds to —
  /// see zambian_term_calendar.dart for how this is computed and verified.
  /// Keyed to [widget.targetTerm] — the term the teacher explicitly picked
  /// — rather than inferred from which topics [entries] happens to contain,
  /// since coverage (not the picked term's own original topic list) now
  /// drives that and could legitimately span more than one real term. Only
  /// computed when a valid 4-digit year is also available; returns null
  /// (silently omitted from the document) otherwise rather than guessing.
  String? _realCalendarNote() {
    final termNumber = widget.targetTerm?.sequenceNumber;
    final year = int.tryParse(_controllers['year']?.text.trim() ?? '');
    if (termNumber == null || termNumber < 1 || termNumber > 3) return null;
    if (year == null || year < 2000 || year > 2100) return null;

    final term = computeZambianSchoolYear(year).term(termNumber);
    String fmt(DateTime d) => '${d.day} ${_monthName(d.month)}';
    return 'Real Ministry of Education calendar: opens ${fmt(term.open)}, closes ${fmt(term.close)}. '
        'Mid-term break: ${fmt(term.midtermBreakStart)}–${fmt(term.midtermBreakEnd)}.';
  }

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String _monthName(int month) => _monthNames[month - 1];

  Future<void> _export(bool asPdf) async {
    _syncDraftFromControllers();
    setState(() => _exporting = true);
    try {
      final file = asPdf
          ? await _documentService.generatePdf(_context, _draft, relatedMarkingKeys: _relatedMarkingKeys)
          : await _documentService.generateDocx(_context, _draft, relatedMarkingKeys: _relatedMarkingKeys);
      if (!mounted) return;
      // The OS share sheet is what actually surfaces WhatsApp, email,
      // Bluetooth, and every other installed share target — one call here
      // covers all of them rather than integrating each one separately.
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Scheme of Work — ${widget.template.subject.name} ${widget.template.grade.name}',
      ));
      for (final entry in widget.entries) {
        unawaited(_lessonHistoryRepository.logSchemeGenerated(
          curriculumCode: widget.template.curriculum.code,
          subjectCode: widget.template.subject.code,
          gradeLevel: widget.template.grade.level,
          topicId: entry.topic.id,
          subTopicId: entry.subTopic?.id,
        ));
      }
      // Auto-advances this class's own resume cursor to the end of what was
      // just generated and shared — the default a future ClassResumePicker
      // lookup suggests, not a silent decision: the teacher still confirms
      // (or overrides) it next time, same as every other generation. A
      // per-row "mark taught" below can later move this cursor BACK if the
      // class didn't actually get through everything shared here. Skipped
      // entirely when there's no real class attached (see classLabel's own
      // doc comment).
      if (widget.classLabel case final label? when widget.entries.isNotEmpty) {
        final last = widget.entries.last;
        unawaited(_classProgressRepository.markConcluded(
          curriculumCode: widget.template.curriculum.code,
          subjectCode: widget.template.subject.code,
          gradeLevel: widget.template.grade.level,
          classLabel: label,
          topicId: last.topic.id,
          subTopicId: last.subTopic?.id,
        ));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the document: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _shareFullSyllabus({required bool asDocx}) async {
    setState(() => _sharingSyllabus = true);
    try {
      final file = asDocx
          ? await _syllabusDocumentService.generateDocx(widget.template)
          : await _syllabusDocumentService.generatePdf(widget.template);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Syllabus — ${widget.template.subject.name} ${widget.template.grade.name}',
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the file: $error')),
      );
    } finally {
      if (mounted) setState(() => _sharingSyllabus = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scheme of Work'),
        actions: [
          _sharingSyllabus
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : PopupMenuButton<bool>(
                  icon: const Icon(Icons.menu_book_outlined),
                  tooltip: 'Print / share full syllabus',
                  onSelected: (asDocx) => _shareFullSyllabus(asDocx: asDocx),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: true, child: Text('Share full syllabus (Word)')),
                    PopupMenuItem(value: false, child: Text('Share full syllabus (PDF)')),
                  ],
                ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          if (_enrichingAi) ...[
            Row(
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Filling in content for a few topics with no real syllabus content yet…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Text(
            '${_activeTemplate.name} layout. ${[for (final c in _activeTemplate.columns) if (c.autoFilled) c.label].join(', ')} '
            'are filled in from the syllabus already on your device. '
            '${[for (final c in _activeTemplate.columns) if (c.suggested) c.label].join(', ')} get a suggested '
            'starting point you should review and adjust — check the remaining columns below before exporting.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          Text('Document details', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _textField('schoolName', 'Name of School'),
          _textField('teacherName', 'Name of Teacher'),
          _textField('year', 'Year', helper: 'e.g. 2026'),
          _textField('philosophy', 'Curriculum Philosophy and Goals',
              maxLines: 3, helper: 'Optional — shown once at the top of the document, not per week.'),
          const SizedBox(height: 16),
          for (var i = 0; i < _draft.rows.length; i++) _buildRowCard(i),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exporting ? null : () => _export(false),
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Export Word'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _exporting ? null : () => _export(true),
                  icon: _exporting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Export PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(String controllerKey, String label, {int maxLines = 1, String? helper}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: _controllers[controllerKey],
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder()),
      ),
    );
  }

  /// The one remaining place a teacher can mark a topic as actually taught
  /// (not just generated) — upgrades its lesson-history entry from
  /// 'generated' to 'completed' (see [LessonHistoryRepository]), same
  /// underlying action the old per-topic Scheme of Work browser used to
  /// offer, now offered per row here instead since that screen no longer
  /// sits in the "Generate Scheme of Work" flow.
  /// Marks every topic in this row taught — for OBC's merged-week rows,
  /// that can be more than one topic at once. Never called with no real
  /// class attached — the button itself is hidden in that case (see the
  /// `trailing` builder above).
  Future<void> _markTaught(List<SchemeOfWorkEntry> entries) async {
    final label = widget.classLabel;
    if (label == null) return;
    for (final entry in entries) {
      await _classProgressRepository.markConcluded(
        curriculumCode: widget.template.curriculum.code,
        subjectCode: widget.template.subject.code,
        gradeLevel: widget.template.grade.level,
        classLabel: label,
        topicId: entry.topic.id,
        subTopicId: entry.subTopic?.id,
      );
    }
    if (!mounted) return;
    setState(() => _markedTaughtTopicIds.addAll(entries.map((e) => e.topic.id)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Marked ${entries.length == 1 ? '"${entries.first.title}"' : 'this week'} as taught.')),
    );
  }

  Widget _buildRowCard(int index) {
    final row = _draft.rows[index];
    final entries = row.entries;
    // A synthetic row (the Mid-Term Break the calendar-pacing engine
    // always inserts — see SchemeOfWorkDocumentDraft._insertMidtermBreakRow)
    // has no real topic behind it: `entries` is deliberately empty, so
    // `row.primaryEntry` (`entries.first`) would throw ("Bad state: No
    // element") — this was a real crash, confirmed 2026-08-31, on any
    // term whose real week data left week 7 unclaimed. Every value the
    // rest of this method needs is read from `row`/`entries` directly
    // rather than through `primaryEntry` for that reason.
    final isSpecialRow = row.specialRowLabel != null;
    final taught = !isSpecialRow && entries.every((e) => _markedTaughtTopicIds.contains(e.topic.id));
    final week = row.displayWeekNumber;
    final competencies = entries.expand((e) => e.competencies).map((c) => c.description).toList();
    final objectives = entries.expand((e) => e.objectives).map((o) => o.description).toList();
    final title = isSpecialRow ? row.specialRowLabel! : entries.map((e) => e.title).join('; ');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        title: Text('Week $week — $title'),
        subtitle: _activeTemplate.columns.any((c) => c.id == 'stage') ? Text('Lesson ${row.lessonNumber}') : null,
        trailing: isSpecialRow || widget.classLabel == null
            ? null
            : IconButton(
                icon: Icon(
                  taught ? Icons.check_circle : Icons.check_circle_outline,
                  color: taught ? Colors.green : null,
                ),
                tooltip: taught ? 'Marked as taught' : 'Mark as taught',
                onPressed: taught ? null : () => _markTaught(entries),
              ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (competencies.isNotEmpty) ...[
            _readOnlyBlock('Specific Competence / Outcomes', competencies),
            const SizedBox(height: 8),
          ],
          if (objectives.isNotEmpty) ...[
            _readOnlyBlock('Learning Activities', objectives),
            const SizedBox(height: 8),
          ],
          if (row.aiEnrichedColumnIds.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 14, color: Theme.of(context).colorScheme.tertiary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'This app had no real content for this topic yet — AI filled the field(s) below, '
                    'grounded in the real syllabus topic. Please review before relying on it.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.tertiary, fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          for (final column in _editableColumnsFor(row))
            _textField(
              'row_${index}_${column.id}',
              column.label,
              maxLines: column.id == 'learningActivities' ? 3 : 2,
              helper: row.aiEnrichedColumnIds.contains(column.id) ? 'AI-suggested — review before use' : null,
            ),
        ],
      ),
    );
  }

  Widget _readOnlyBlock(String label, Iterable<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        for (final item in items) Text('•  $item'),
      ],
    );
  }
}
