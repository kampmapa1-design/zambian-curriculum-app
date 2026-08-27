import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/lesson_history_entry.dart';
import '../models/record_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/lesson_history_repository.dart';
import '../services/record_of_work_document_service.dart';

/// "Generate Record of Work": once a subject/class and a Weekly/Fortnightly
/// period are picked, this screen lets the teacher confirm the date range,
/// automatically pulls matching entries from the app's own lesson history
/// (see [LessonHistoryRepository] — no manual re-entry of what was already
/// generated/taught), fills in the auto part of each row, and leaves the
/// manual columns (periods, remarks, attendance, signatures — see
/// [defaultRecordOfWorkTemplate]) for the teacher to complete before
/// exporting as PDF/Word, same share path as every other export in this
/// app.
class RecordOfWorkScreen extends StatefulWidget {
  const RecordOfWorkScreen({
    super.key,
    required this.template,
    required this.period,
    this.lessonHistoryRepository,
    this.documentService,
    this.recordTemplate = defaultRecordOfWorkTemplate,
  });

  final SyllabusTemplate template;
  final RecordOfWorkPeriod period;
  final LessonHistoryRepository? lessonHistoryRepository;
  final RecordOfWorkDocumentService? documentService;
  final RecordOfWorkTemplate recordTemplate;

  @override
  State<RecordOfWorkScreen> createState() => _RecordOfWorkScreenState();
}

class _RecordOfWorkScreenState extends State<RecordOfWorkScreen> {
  late final LessonHistoryRepository _historyRepository = widget.lessonHistoryRepository ?? LessonHistoryRepository();
  late final RecordOfWorkDocumentService _documentService = widget.documentService ?? RecordOfWorkDocumentService();

  late DateTime _rangeEnd;
  late DateTime _rangeStart;
  bool _loading = true;
  bool _exporting = false;
  List<RecordOfWorkRow> _rows = const [];
  RecordOfWorkStatus _status = RecordOfWorkStatus.pending;
  final _schoolNameController = TextEditingController();
  final _teacherNameController = TextEditingController();
  final Map<int, Map<String, TextEditingController>> _rowControllers = {};

  @override
  void initState() {
    super.initState();
    _rangeEnd = DateTime.now();
    _rangeStart = _rangeEnd.subtract(widget.period.duration);
    _load();
  }

  @override
  void dispose() {
    _schoolNameController.dispose();
    _teacherNameController.dispose();
    for (final controllers in _rowControllers.values) {
      for (final c in controllers.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await _historyRepository.query(
      from: DateTime(_rangeStart.year, _rangeStart.month, _rangeStart.day),
      to: DateTime(_rangeEnd.year, _rangeEnd.month, _rangeEnd.day, 23, 59, 59),
      curriculumCode: widget.template.curriculum.code,
      subjectCode: widget.template.subject.code,
      gradeLevel: widget.template.grade.level,
    );
    if (!mounted) return;
    setState(() {
      _rows = _dedupeEntries(entries).map(RecordOfWorkRow.fromLessonHistory).toList();
      _rebuildRowControllers();
      _loading = false;
    });
  }

  /// A topic often has both a 'generated' and a 'completed' history entry
  /// (a lesson plan was made, then the topic was later marked concluded) —
  /// collapse those into one row per topic/sub-topic rather than listing
  /// the same lesson twice, preferring the 'completed' entry's date since
  /// that's when it was actually taught.
  List<LessonHistoryEntry> _dedupeEntries(List<LessonHistoryEntry> entries) {
    final byTopic = <String, LessonHistoryEntry>{};
    for (final entry in entries) {
      final key = '${entry.topicId}|${entry.subTopicId}';
      final existing = byTopic[key];
      if (existing == null || entry.status == LessonHistoryStatus.completed) {
        byTopic[key] = entry;
      }
    }
    final result = byTopic.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  void _rebuildRowControllers() {
    for (final controllers in _rowControllers.values) {
      for (final c in controllers.values) {
        c.dispose();
      }
    }
    _rowControllers.clear();
    for (var i = 0; i < _rows.length; i++) {
      _rowControllers[i] = {
        for (final column in widget.recordTemplate.manualColumns) column.id: TextEditingController(),
      };
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _rangeStart : _rangeEnd,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _rangeStart = picked;
      } else {
        _rangeEnd = picked;
      }
    });
    await _load();
  }

  void _syncRowsFromControllers() {
    final updated = <RecordOfWorkRow>[];
    for (var i = 0; i < _rows.length; i++) {
      var row = _rows[i];
      final controllers = _rowControllers[i] ?? const {};
      for (final entry in controllers.entries) {
        row = row.withManualValue(entry.key, entry.value.text);
      }
      updated.add(row);
    }
    _rows = updated;
  }

  Future<void> _export(bool asPdf) async {
    _syncRowsFromControllers();
    setState(() => _exporting = true);
    try {
      final draft = RecordOfWorkDraft(
        schoolName: _schoolNameController.text,
        teacherName: _teacherNameController.text,
        curriculumName: widget.template.curriculum.name,
        subjectName: widget.template.subject.name,
        className: widget.template.grade.name,
        period: widget.period,
        rangeStart: _rangeStart,
        rangeEnd: _rangeEnd,
        status: _status,
        rows: _rows,
      );
      final file = asPdf
          ? await _documentService.generatePdf(widget.recordTemplate, draft)
          : await _documentService.generateDocx(widget.recordTemplate, draft);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Record of Work — ${widget.template.subject.name} ${widget.template.grade.name}',
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the document: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Record of Work — ${widget.template.subject.name} ${widget.template.grade.name}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                Text('${widget.period.label} record', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _pickDate(isStart: true),
                        child: Text('From: ${_fmt(_rangeStart)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _pickDate(isStart: false),
                        child: Text('To: ${_fmt(_rangeEnd)}'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _schoolNameController,
                  decoration: const InputDecoration(labelText: 'School', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _teacherNameController,
                  decoration: const InputDecoration(labelText: 'Teacher', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<RecordOfWorkStatus>(
                  decoration: const InputDecoration(labelText: 'Status', border: OutlineInputBorder()),
                  initialValue: _status,
                  items: [
                    for (final s in RecordOfWorkStatus.values) DropdownMenuItem(value: s, child: Text(s.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _status = v);
                  },
                ),
                const Divider(height: 32),
                Text('Lessons in this period', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  _rows.isEmpty
                      ? 'No lesson plan or scheme was generated, and no topic marked taught, for this '
                          'subject/class in this date range.'
                      : '${_rows.length} pulled automatically from your lesson history. Fill in periods, '
                          'remarks, attendance, and signatures below before exporting.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < _rows.length; i++) _buildRowCard(i),
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

  Widget _buildRowCard(int index) {
    final row = _rows[index];
    final controllers = _rowControllers[index]!;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_fmt(row.date), style: Theme.of(context).textTheme.labelMedium),
            Text(row.topicLabel, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final column in widget.recordTemplate.manualColumns) ...[
              if (column.id == 'remarks' && widget.recordTemplate.standardRemarks.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final remark in widget.recordTemplate.standardRemarks)
                      ActionChip(
                        label: Text(remark, style: const TextStyle(fontSize: 11)),
                        onPressed: () => setState(() => controllers[column.id]!.text = remark),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextFormField(
                  controller: controllers[column.id],
                  maxLines: column.type == RecordOfWorkColumnType.multiline ? 2 : 1,
                  keyboardType:
                      column.type == RecordOfWorkColumnType.number ? TextInputType.number : TextInputType.text,
                  decoration: InputDecoration(labelText: column.label, isDense: true, border: const OutlineInputBorder()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
