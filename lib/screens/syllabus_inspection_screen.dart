import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/pupil_class_link_service.dart';
import '../services/syllabus_pacing.dart';
import '../services/template_repository.dart';
import '../theme/app_spacing.dart';

/// "Syllabus Inspection" (owner request, 2026-09-29) — read-only, for
/// learners who've joined a class. Real, disclosed scope decision: the
/// ORIGINAL spec asked for real per-topic "Covered/In Progress/Not Yet
/// Covered" status pulled from the same tracking Record of Work uses —
/// found to be genuinely impossible as specified, since that tracking data
/// is "purely on-device" to the TEACHER (see LessonHistoryRepository's own
/// doc comment) and never synced anywhere a pupil's device could read it.
/// The owner redirected this to a zero-cost, zero-new-infrastructure
/// version instead: the syllabus's own real planned topic order, with an
/// honest proportional-pacing approximation of where the year currently
/// sits — never a claim about what's actually been taught in class. See
/// [syllabusPacingFor]'s own doc comment for exactly how that's computed
/// and why it's disclosed as an approximation, not a tracked record.
///
/// Also real, disclosed: School Network class records store `classGrade`/
/// `subjectNames` as free-text strings, not structured curriculum/grade/
/// subject codes — there's no reliable way to auto-derive which bundled
/// syllabus a class corresponds to. So "joined a class" is used only as
/// the real, structured GATE (`PupilClassLinkService.currentPupilClaim`),
/// and the actual subject to inspect is picked directly from the app's
/// own real bundled syllabus list — same structured data every other
/// syllabus-driven screen in this app already uses — rather than guessed
/// from the class's own free text.
class SyllabusInspectionScreen extends StatefulWidget {
  const SyllabusInspectionScreen({super.key, this.classLinkService, this.templateRepository});

  final PupilClassLinkService? classLinkService;
  final TemplateRepository? templateRepository;

  @override
  State<SyllabusInspectionScreen> createState() => _SyllabusInspectionScreenState();
}

class _SyllabusInspectionScreenState extends State<SyllabusInspectionScreen> {
  late final PupilClassLinkService _classLinkService = widget.classLinkService ?? PupilClassLinkService();
  late final TemplateRepository _templateRepository = widget.templateRepository ?? TemplateRepository();

  bool _loading = true;
  bool _hasJoinedClass = false;
  List<TemplateManifestEntry> _manifest = const [];

  String? _curriculumCode;
  int? _gradeLevel;
  String? _subjectCode;

  SyllabusTemplate? _template;
  SyllabusPacingResult? _pacing;
  bool _loadingSyllabus = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final claim = await _classLinkService.currentPupilClaim();
    await _templateRepository.ensureAllSeeded();
    final manifest = await _templateRepository.loadManifest();
    if (!mounted) return;
    setState(() {
      _hasJoinedClass = claim.classId != null;
      _manifest = manifest;
      _loading = false;
    });
  }

  List<TemplateManifestEntry> get _curricula {
    final seen = <String>{};
    return [
      for (final e in _manifest)
        if (seen.add(e.curriculumCode)) e,
    ];
  }

  List<TemplateManifestEntry> get _gradesForCurriculum {
    final seen = <int>{};
    return [
      for (final e in _manifest)
        if (e.curriculumCode == _curriculumCode && seen.add(e.gradeLevel)) e,
    ];
  }

  List<TemplateManifestEntry> get _subjectsForGrade => _manifest
      .where((e) => e.curriculumCode == _curriculumCode && e.gradeLevel == _gradeLevel)
      .toList()
    ..sort((a, b) => a.subjectName.compareTo(b.subjectName));

  Future<void> _loadSyllabus(TemplateManifestEntry entry) async {
    setState(() => _loadingSyllabus = true);
    final template = await _templateRepository.loadSyllabus(
      curriculumCode: entry.curriculumCode,
      subjectCode: entry.subjectCode,
      gradeLevel: entry.gradeLevel,
    );
    if (!mounted) return;
    setState(() {
      _subjectCode = entry.subjectCode;
      _template = template;
      _pacing = template == null ? null : syllabusPacingFor(template);
      _loadingSyllabus = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Syllabus Inspection')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_hasJoinedClass
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Join a class first — this is only available to learners linked to a real class.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _template != null
                  ? _buildTopicList(context)
                  : _buildPicker(context),
    );
  }

  Widget _buildPicker(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        const Text('Pick your curriculum, grade, and subject to see its planned topic order.'),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<String>(
          initialValue: _curriculumCode,
          decoration: const InputDecoration(labelText: 'Curriculum', border: OutlineInputBorder()),
          items: [
            for (final c in _curricula) DropdownMenuItem(value: c.curriculumCode, child: Text(c.curriculumName)),
          ],
          onChanged: (v) => setState(() {
            _curriculumCode = v;
            _gradeLevel = null;
          }),
        ),
        const SizedBox(height: AppSpacing.sm),
        DropdownButtonFormField<int>(
          initialValue: _gradeLevel,
          decoration: const InputDecoration(labelText: 'Grade', border: OutlineInputBorder()),
          items: [
            for (final g in _gradesForCurriculum) DropdownMenuItem(value: g.gradeLevel, child: Text(g.gradeName)),
          ],
          onChanged: _curriculumCode == null ? null : (v) => setState(() => _gradeLevel = v),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_gradeLevel != null)
          for (final subject in _subjectsForGrade)
            Card(
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: ListTile(
                title: Text(subject.subjectName),
                trailing: _loadingSyllabus && _subjectCode == subject.subjectCode
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right_outlined),
                onTap: _loadingSyllabus ? null : () => _loadSyllabus(subject),
              ),
            ),
      ],
    );
  }

  Widget _buildTopicList(BuildContext context) {
    final template = _template!;
    final pacing = _pacing!;
    if (pacing.entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No coverage data available yet for ${template.subject.name}.', textAlign: TextAlign.center),
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${template.subject.name} — ${template.grade.name}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text(
                "This is the syllabus's own planned topic order, not a record of what's actually been taught. "
                'The "≈ Approximately here now" marker is a rough estimate based on the school calendar, not a '
                "tracked position — ask your teacher for the real pace of your class.",
                style: TextStyle(fontSize: 12),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _template = null;
                  _pacing = null;
                }),
                child: const Text('Choose a different subject'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(AppSpacing.md),
            itemCount: pacing.entries.length,
            itemBuilder: (context, index) {
              final entry = pacing.entries[index];
              final isNow = index == pacing.approximateCurrentIndex;
              return _TopicRow(entry: entry, isApproximatelyNow: isNow);
            },
          ),
        ),
      ],
    );
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow({required this.entry, required this.isApproximatelyNow});

  final SchemeOfWorkEntry entry;
  final bool isApproximatelyNow;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      color: isApproximatelyNow ? colorScheme.primaryContainer : null,
      child: ListTile(
        leading: isApproximatelyNow ? Icon(Icons.my_location_outlined, color: colorScheme.onPrimaryContainer) : null,
        title: Text(
          entry.title,
          style: TextStyle(
            fontWeight: isApproximatelyNow ? FontWeight.bold : FontWeight.normal,
            color: isApproximatelyNow ? colorScheme.onPrimaryContainer : null,
          ),
        ),
        subtitle: isApproximatelyNow
            ? Text('≈ Approximately here now', style: TextStyle(color: colorScheme.onPrimaryContainer))
            : null,
      ),
    );
  }
}
