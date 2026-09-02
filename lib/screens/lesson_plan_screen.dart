import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/embedded_lesson_plan.dart';
import '../models/lesson_checkpoint.dart';
import '../models/lesson_plan.dart';
import '../models/lesson_stage.dart';
import '../models/marking_scheme.dart';
import '../models/scheme_of_work.dart';
import '../models/subject_content_item.dart';
import '../services/custom_template_repository.dart';
import '../services/embedded_lesson_plan_repository.dart';
import '../services/lesson_checkpoint_repository.dart';
import '../services/lesson_history_repository.dart';
import '../services/lesson_plan_ai_service.dart';
import '../services/lesson_plan_document_service.dart';
import '../services/lesson_progression_generator.dart';
import '../services/subject_content_index.dart';
import '../services/teaching_notes_document_service.dart';
import '../services/teaching_notes_service.dart';

/// Lets a teacher fill in a lesson plan template for one scheme-of-work
/// entry (topic/sub-topic already known from the syllabus), then export it
/// as Word and share it — entirely on-device, no network required. When
/// online, sharing also generates and attaches a companion "Lesson Notes"
/// document (2026-09-02, per explicit request) — a one-page bulletin
/// summary of the whole topic, reusing the same AI-enhanced Teaching
/// Notes pipeline "Generate Teaching Notes & Slides" already has, capped
/// to roughly a page (see `maxLength: 'page'` on `generateTeachingNotes`).
/// Word-only (2026-09-02, per the same request) — PDF export was removed.
///
/// Defaults to the bundled CDC template, but also offers any templates the
/// teacher uploaded themselves (Stage 3: "Upload My Own Template",
/// see [CustomTemplateRepository]) — switching templates rebuilds the form
/// around the newly selected field definitions.
///
/// Stage 6: "Resume Lesson" — the teacher can mark which Lesson Progression
/// stage they reached and save a checkpoint; opening the same lesson again
/// (identified by curriculum + subject + grade + topic + sub-topic) offers
/// to continue from there instead of starting over.
class LessonPlanScreen extends StatefulWidget {
  const LessonPlanScreen({
    super.key,
    required this.subjectName,
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.entry,
    this.template = defaultCdcLessonPlanTemplate,
    this.documentService,
    this.customTemplateRepository,
    this.checkpointRepository,
    this.embeddedLessonPlanRepository,
    this.lessonPlanAiService,
    this.notesService,
    this.notesDocumentService,
    this.guidedActivitiesText,
    this.guidedNoteText,
    this.focusStage,
  });

  final String subjectName;
  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final SchemeOfWorkEntry entry;
  final LessonPlanTemplate template;
  final LessonPlanDocumentService? documentService;
  final CustomTemplateRepository? customTemplateRepository;
  final LessonCheckpointRepository? checkpointRepository;
  final EmbeddedLessonPlanRepository? embeddedLessonPlanRepository;
  final LessonPlanAiService? lessonPlanAiService;

  /// The companion "Lesson Notes" document's AI generation (2026-09-02) —
  /// reuses the same `generateTeachingNotes` pipeline "Generate Teaching
  /// Notes & Slides" already has, just capped to one page (see
  /// [TeachingNotesService.generate]'s `onePage` parameter).
  final TeachingNotesService? notesService;
  final TeachingNotesDocumentService? notesDocumentService;

  /// Pre-fills the "Lesson Development" progression stage's Learners' Role
  /// (or the first stage, if none is named "Development") — set when
  /// arriving from Stage 5's guided planning with a chosen set of
  /// activities. Ignored for templates with no progression stages (e.g. a
  /// custom uploaded one), and superseded if the teacher chooses to resume
  /// a saved checkpoint instead.
  final String? guidedActivitiesText;

  /// Paired with [guidedActivitiesText]: suggested group size and any rule
  /// notices from guided planning, pre-filled into the same stage's
  /// Teacher's Role.
  final String? guidedNoteText;

  /// Restricts a freshly generated lesson plan to just this conceptual
  /// stage's real progression rows (see [LessonStage.matchingIndices]) —
  /// set by the "Generate Lesson Plan" entry flow when the teacher picked
  /// which part of the lesson (Introduction/Main Body/Conclusion) this
  /// specific 40-minute lesson plan should cover, rather than always
  /// generating every stage from Introduction through Conclusion in one
  /// document. Null shows every stage (e.g. opened directly from a Scheme
  /// of Work entry card, with no stage question asked). Ignored when
  /// resuming a checkpoint — that draft's progression is whatever was saved.
  final LessonStage? focusStage;

  @override
  State<LessonPlanScreen> createState() => _LessonPlanScreenState();
}

class _LessonPlanScreenState extends State<LessonPlanScreen> {
  late final LessonPlanDocumentService _documentService = widget.documentService ?? LessonPlanDocumentService();
  late final CustomTemplateRepository _customTemplateRepository =
      widget.customTemplateRepository ?? CustomTemplateRepository();
  late final LessonCheckpointRepository _checkpointRepository =
      widget.checkpointRepository ?? LessonCheckpointRepository();
  late final SubjectContentIndex _contentIndex =
      SubjectContentIndex(embeddedLessonPlanRepository: widget.embeddedLessonPlanRepository);
  final LessonHistoryRepository _lessonHistoryRepository = LessonHistoryRepository();
  late final LessonPlanAiService _aiService = widget.lessonPlanAiService ?? LessonPlanAiService();
  late final TeachingNotesService _notesService = widget.notesService ?? TeachingNotesService();
  late final TeachingNotesDocumentService _notesDocumentService =
      widget.notesDocumentService ?? TeachingNotesDocumentService();

  List<LessonPlanTemplate> _availableTemplates = const [];
  late LessonPlanTemplate _activeTemplate;
  late LessonPlanDraft _draft;
  final Map<String, TextEditingController> _controllers = {};
  bool _exporting = false;
  bool _generatingAi = false;
  int? _reachedStageIndex;
  List<EmbeddedLessonPlan> _embeddedMatches = const [];
  bool _usingEmbedded = false;
  List<SubjectContentItem> _relatedMaterials = const [];
  String? _subjectContentExcerpt;
  List<MarkingScheme> _relatedMarkingKeys = const [];

  @override
  void initState() {
    super.initState();
    _activeTemplate = widget.template;
    _availableTemplates = [widget.template];
    _rebuildForActiveTemplate();
    _loadCustomTemplates();
    _loadSubjectContentIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForCheckpoint());
  }

  /// Everything this app already knows on-device about this exact
  /// topic/sub-topic — embedded real lesson plans, related Subject Content
  /// Database materials, a matching content excerpt, and related marking
  /// keys — resolved in one coordinated call via [SubjectContentIndex]
  /// rather than four separate uncoordinated futures. Entirely local/offline
  /// (see [SubjectContentIndex]'s own doc comment) but still done async,
  /// after the initial synchronous build, so opening the screen never waits
  /// on a disk scan. Silently does nothing on failure — the syllabus-derived
  /// progression already shown stands on its own; this only enriches it.
  Future<void> _loadSubjectContentIndex() async {
    try {
      final resolution = await _contentIndex.resolve(
        subjectName: widget.subjectName,
        curriculumCode: widget.curriculumCode,
        subjectCode: widget.subjectCode,
        gradeLevel: widget.gradeLevel,
        topicName: widget.entry.topic.name,
        subTopicName: widget.entry.subTopic?.name,
      );
      if (!mounted) return;
      setState(() {
        if (resolution.embeddedLessonPlans.isNotEmpty) _embeddedMatches = resolution.embeddedLessonPlans;
        if (resolution.relatedMaterials.isNotEmpty) _relatedMaterials = resolution.relatedMaterials;
        if (resolution.relatedMarkingKeys.isNotEmpty) _relatedMarkingKeys = resolution.relatedMarkingKeys;
      });
      if (resolution.contentExcerpt != null) {
        _subjectContentExcerpt = resolution.contentExcerpt;
        _mergeExcerptIntoDevelopmentRow(resolution.contentExcerpt!);
      }
    } catch (_) {
      // Best-effort enrichment only.
    }
  }

  /// Patches just the Development-stage progression row with the excerpt,
  /// rather than rebuilding the whole draft — this can land after the
  /// teacher has already started editing other fields, and a full rebuild
  /// would silently discard that work.
  void _mergeExcerptIntoDevelopmentRow(String excerpt) {
    final devIndex = _draft.progression.indexWhere((r) => r.stage.toLowerCase().contains('development'));
    if (devIndex == -1) return;

    final regenerated = generateDefaultProgression(
      _activeTemplate.progressionStages,
      widget.entry,
      subjectContentExcerpt: excerpt,
    );
    if (devIndex >= regenerated.length) return;

    setState(() {
      _draft = _draft.withProgressionRow(devIndex, regenerated[devIndex]);
      _controllers['progression_${devIndex}_teacher']?.text = regenerated[devIndex].teacherRole;
    });
  }

  Future<void> _openRelatedMaterial(SubjectContentItem item) async {
    final file = await _contentIndex.fileFor(item);
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: item.title));
  }

  /// Replaces the current (generated) draft's content with a real embedded
  /// lesson plan — sanitized, never fabricated. Auto-filled header fields
  /// (subject/topic/sub-topic/competences, already syllabus-derived) are
  /// left as they are; only the planning fields and progression come from
  /// the embedded source. Still fully editable afterwards, same as any
  /// other draft.
  void _applyEmbedded(EmbeddedLessonPlan plan) {
    final values = Map<String, String>.from(_draft.values);
    void set(String id, String? value) {
      if (value != null && value.trim().isNotEmpty) values[id] = value;
    }

    set('rationale', plan.rationale);
    set('priorKnowledge', plan.priorKnowledge);
    set('references', plan.references);
    set('tlm', plan.tlm);
    set('majorLearningPoint', plan.majorLearningPoint);
    set('lessonGoal', plan.lessonGoal);
    set('duration', plan.duration);
    if (plan.objectives.isNotEmpty) values['expectedStandard'] = plan.objectives.join('\n');

    var progression = [
      for (final row in plan.progression)
        LessonProgressionRow(stage: row.stage, teacherRole: row.teacherRole ?? '', learnersRole: row.learnersRole ?? ''),
    ];
    final focus = widget.focusStage;
    if (focus != null && progression.isNotEmpty) {
      final stageNames = [for (final r in progression) r.stage];
      final keep = focus.matchingIndices(stageNames).toSet();
      final filtered = [for (var i = 0; i < progression.length; i++) if (keep.contains(i)) progression[i]];
      if (filtered.isNotEmpty) progression = filtered;
    }
    if (progression.isEmpty) progression = _draft.progression;

    setState(() {
      _usingEmbedded = true;
      _reachedStageIndex = null;
      _rebuildForActiveTemplate(seedDraft: LessonPlanDraft(values: values, progression: progression));
    });
  }

  /// Optional, request-time AI upgrade — calls `generateLessonPlan` and
  /// merges the result onto the current draft. Grounded in this entry's
  /// real syllabus competencies/objectives/references FIRST, and — when
  /// available — real material already saved on this device for this
  /// exact topic (`_subjectContentExcerpt`, from the Subject Content
  /// Database or a matching embedded lesson plan, see
  /// `_loadSubjectContentIndex`), passed through so the server-side
  /// prompt grounds itself there before falling back to general knowledge
  /// (2026-09-02, per explicit request: "consult device repositories...
  /// and access online relevant ones where necessary"). Existing edits to
  /// fields the AI wasn't asked about (header details, evaluation) are
  /// untouched — same "enrich, don't discard" principle as
  /// [_applyEmbedded] and [_mergeExcerptIntoDevelopmentRow].
  Future<void> _generateWithAi() async {
    _syncDraftFromControllers();
    setState(() => _generatingAi = true);
    try {
      final competencies = widget.entry.competencies.map((c) => c.description).toList();
      final objectives = widget.entry.objectives.map((o) => o.description).toList();
      final result = await _aiService.generate(
        topic: widget.entry.topic.name,
        subtopic: widget.entry.subTopic?.name,
        subjectContentExcerpt: _subjectContentExcerpt,
        competencies: competencies,
        objectives: objectives,
        references: widget.entry.references,
        progressionStages: _activeTemplate.progressionStages,
      );
      if (!mounted) return;

      var values = Map<String, String>.from(_draft.values);
      void set(String id, String value) {
        if (value.trim().isNotEmpty && _activeTemplate.allFields.any((f) => f.id == id)) values[id] = value;
      }

      set('rationale', result.rationale);
      set('priorKnowledge', result.priorKnowledge);
      set('tlm', result.tlm);
      set('expectedStandard', result.expectedStandard);

      setState(() {
        _rebuildForActiveTemplate(
          seedDraft: LessonPlanDraft(
            values: values,
            progression: result.mergedProgression(_draft.progression),
          ),
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI-enhanced lesson plan applied — review and edit as needed.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not generate an AI-enhanced lesson plan: $error')),
      );
    } finally {
      if (mounted) setState(() => _generatingAi = false);
    }
  }

  Future<void> _loadCustomTemplates() async {
    final custom = await _customTemplateRepository.list();
    if (!mounted || custom.isEmpty) return;
    setState(() => _availableTemplates = [widget.template, ...custom]);
  }

  Future<void> _checkForCheckpoint() async {
    final checkpoint = await _checkpointRepository.find(
      curriculumCode: widget.curriculumCode,
      subjectCode: widget.subjectCode,
      gradeLevel: widget.gradeLevel,
      topicId: widget.entry.topic.id,
      subTopicId: widget.entry.subTopic?.id,
    );
    if (!mounted || checkpoint == null) return;

    final stages = checkpoint.draft.progression;
    final reachedStageName =
        checkpoint.reachedStageIndex >= 0 && checkpoint.reachedStageIndex < stages.length
            ? stages[checkpoint.reachedStageIndex].stage
            : 'a later stage';

    final resume = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resume this lesson?'),
        content: Text(
          'You reached "$reachedStageName" last time (${_relativeTime(checkpoint.savedAt)}). '
          'Continue from there, or start fresh?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Start fresh')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Resume')),
        ],
      ),
    );
    if (resume != true || !mounted) return;

    final matchingTemplate = _availableTemplates.where((t) => t.id == checkpoint.templateId);
    setState(() {
      if (matchingTemplate.isNotEmpty) _activeTemplate = matchingTemplate.first;
      _rebuildForActiveTemplate(seedDraft: checkpoint.draft);
      _reachedStageIndex = checkpoint.reachedStageIndex;
    });
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Rebuilds `_draft` and every controller around `_activeTemplate`. Pass
  /// [seedDraft] to restore an exact prior draft (resuming a checkpoint);
  /// omitted, a fresh draft is built with the syllabus auto-fill values and
  /// any guided-planning prefill applied.
  void _rebuildForActiveTemplate({LessonPlanDraft? seedDraft}) {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();

    final seed = seedDraft;
    if (seed != null) {
      _draft = seed;
    } else {
      var built = LessonPlanDraft.empty(_activeTemplate)
          .withValue('subject', widget.subjectName)
          .withValue('topic', widget.entry.topic.name);
      if (widget.entry.subTopic != null) {
        built = built.withValue('subTopic', widget.entry.subTopic!.name);
      }
      final generalCompetences = widget.entry.topic.competencies.map((c) => c.description).join('\n');
      if (generalCompetences.isNotEmpty) {
        built = built.withValue('generalCompetences', generalCompetences);
      }
      final specificCompetences = widget.entry.competencies.map((c) => c.description).join('\n');
      if (specificCompetences.isNotEmpty) {
        built = built.withValue('specificCompetences', specificCompetences);
      }
      if (widget.entry.objectives.isNotEmpty) {
        built = built.withValue('expectedStandard', widget.entry.objectives.first.description);
        // CBC template only: "Major Learning Point/Activity" is this specific
        // lesson's slice of the sub-topic — the first not-yet-covered
        // objective is a reasonable default starting point (a sub-topic
        // typically spans several lessons, one per objective).
        built = built.withValue('majorLearningPoint', widget.entry.objectives.first.description);
      }
      if (built.value('lessonGoal').isEmpty && widget.entry.competencies.isNotEmpty) {
        built = built.withValue(
          'lessonGoal',
          'By the end of the lesson, learners will be able to ${widget.entry.competencies.first.description}'
              '${widget.entry.competencies.length > 1 ? ' and related specific competences.' : '.'}',
        );
      }
      // Rationale is picked automatically from the topic's syllabus
      // objectives (falling back to competencies) rather than left for the
      // teacher to compose from scratch — still an editable field, just
      // pre-filled with syllabus-grounded text.
      if (built.value('rationale').isEmpty) {
        final rationaleSource = widget.entry.objectives.isNotEmpty
            ? widget.entry.objectives.map((o) => o.description)
            : widget.entry.competencies.map((c) => c.description);
        if (rationaleSource.isNotEmpty) {
          built = built.withValue(
            'rationale',
            'This lesson matters because, by the end of it, learners will be able to:\n'
                '${rationaleSource.map((s) => '•  $s').join('\n')}',
          );
        }
      }
      if (built.progression.isNotEmpty) {
        // Every stage gets real, syllabus-derived content by default — most
        // topics have no curated Guided Planning activity bank, so without
        // this every row but the auto-filled header stays blank (see
        // lesson_progression_generator.dart).
        final generated = generateDefaultProgression(
          _activeTemplate.progressionStages,
          widget.entry,
          subjectContentExcerpt: _subjectContentExcerpt,
        );
        for (var i = 0; i < generated.length && i < built.progression.length; i++) {
          built = built.withProgressionRow(i, generated[i]);
        }
        if (widget.guidedActivitiesText != null) {
          // Guided Planning's curated, rule-checked activities are richer
          // than the generic default above — let them override just the
          // Development stage when they're available.
          final idx = built.progression.indexWhere((r) => r.stage.toLowerCase().contains('development'));
          final targetIndex = idx == -1 ? 0 : idx;
          built = built.withProgressionRow(
            targetIndex,
            built.progression[targetIndex].copyWith(
              learnersRole: widget.guidedActivitiesText,
              teacherRole: widget.guidedNoteText,
            ),
          );
        }
        final focus = widget.focusStage;
        if (focus != null) {
          // Restrict the generated plan to just the requested stage's real
          // progression rows — a lesson plan "at the Main Body stage" is its
          // own complete 40-minute lesson, not the whole topic end to end.
          final keep = focus.matchingIndices(_activeTemplate.progressionStages).toSet();
          built = LessonPlanDraft(
            values: built.values,
            progression: [for (var i = 0; i < built.progression.length; i++) if (keep.contains(i)) built.progression[i]],
          );
        }
      }
      _draft = built;
    }

    for (final field in _activeTemplate.allFields) {
      _controllers[field.id] = TextEditingController(text: _draft.value(field.id));
    }
    for (var i = 0; i < _draft.progression.length; i++) {
      final row = _draft.progression[i];
      _controllers['progression_${i}_duration'] = TextEditingController(text: row.durationMinutes);
      _controllers['progression_${i}_teacher'] = TextEditingController(text: row.teacherRole);
      _controllers['progression_${i}_learners'] = TextEditingController(text: row.learnersRole);
      _controllers['progression_${i}_assessment'] = TextEditingController(text: row.assessmentCriteria);
    }
  }

  void _onTemplateChanged(LessonPlanTemplate? template) {
    if (template == null || template.id == _activeTemplate.id) return;
    setState(() {
      _activeTemplate = template;
      _reachedStageIndex = null;
      _rebuildForActiveTemplate();
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _syncDraftFromControllers() {
    for (final field in _activeTemplate.allFields) {
      _draft = _draft.withValue(field.id, _controllers[field.id]!.text);
    }
    for (var i = 0; i < _draft.progression.length; i++) {
      _draft = _draft.withProgressionRow(
        i,
        _draft.progression[i].copyWith(
          durationMinutes: _controllers['progression_${i}_duration']!.text,
          teacherRole: _controllers['progression_${i}_teacher']!.text,
          learnersRole: _controllers['progression_${i}_learners']!.text,
          assessmentCriteria: _controllers['progression_${i}_assessment']!.text,
        ),
      );
    }
  }

  Future<void> _saveCheckpoint() async {
    if (_reachedStageIndex == null) return;
    _syncDraftFromControllers();
    await _checkpointRepository.save(LessonCheckpoint(
      curriculumCode: widget.curriculumCode,
      subjectCode: widget.subjectCode,
      gradeLevel: widget.gradeLevel,
      topicId: widget.entry.topic.id,
      subTopicId: widget.entry.subTopic?.id,
      templateId: _activeTemplate.id,
      reachedStageIndex: _reachedStageIndex!,
      draft: _draft,
      savedAt: DateTime.now(),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Progress saved — reached "${_draft.progression[_reachedStageIndex!].stage}".')),
    );
  }

  /// Word-only (2026-09-02, per explicit request — PDF export removed).
  /// When there's a connection, also generates and attaches a companion
  /// "Lesson Notes" document — a one-page bulletin summary of the whole
  /// topic, reusing the same AI pipeline "Generate Teaching Notes &
  /// Slides" already has (see [TeachingNotesService.generate]'s
  /// `onePage`). Best-effort: a failure generating notes (or being
  /// offline) never blocks sharing the lesson plan itself — the teacher
  /// just doesn't get the companion doc that time, and is told plainly why.
  Future<void> _export() async {
    _syncDraftFromControllers();
    setState(() => _exporting = true);
    try {
      final planFile = await _documentService.generateDocx(_activeTemplate, _draft, relatedMarkingKeys: _relatedMarkingKeys);
      final files = [XFile(planFile.path)];
      var notesIncluded = false;

      if (await _notesService.isOnline) {
        try {
          final notesResult = await _notesService.generate(
            topic: widget.entry.topic.name,
            subtopic: widget.entry.subTopic?.name,
            syllabusContext: _lessonNotesSyllabusContext(),
            format: 'bullet',
            onePage: true,
          );
          final notesFile = await _notesDocumentService.generateDocx(
            title: 'Lesson Notes — ${widget.entry.title}',
            notes: notesResult.notes,
          );
          files.add(XFile(notesFile.path));
          notesIncluded = true;
        } catch (_) {
          // Best-effort only — the lesson plan itself still shares below.
        }
      }

      if (!mounted) return;
      // The OS share sheet is what actually surfaces WhatsApp, email,
      // Bluetooth, and every other installed share target — one call here
      // covers all of them rather than integrating each one separately.
      await SharePlus.instance.share(ShareParams(
        files: files,
        subject: 'Lesson Plan — ${widget.entry.topic.name}',
      ));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(notesIncluded
              ? 'Shared the lesson plan with a companion Lesson Notes document.'
              : "Shared the lesson plan — connect to the internet to also include Lesson Notes next time."),
        ));
      }
      unawaited(_lessonHistoryRepository.logLessonPlanGenerated(
        curriculumCode: widget.curriculumCode,
        subjectCode: widget.subjectCode,
        gradeLevel: widget.gradeLevel,
        topicId: widget.entry.topic.id,
        subTopicId: widget.entry.subTopic?.id,
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

  /// The same topic/objectives/competencies context every syllabus-
  /// grounded generation call uses, plus — when available — real
  /// material already saved on this device for this exact topic (see
  /// `_generateWithAi`'s doc comment for the same principle applied
  /// there).
  String _lessonNotesSyllabusContext() {
    final excerpt = _subjectContentExcerpt;
    return [
      'Topic: ${widget.entry.topic.name}',
      if (widget.entry.subTopic != null) 'Sub-topic: ${widget.entry.subTopic!.name}',
      for (final o in widget.entry.objectives) 'Learning objective: ${o.description}',
      for (final c in widget.entry.competencies) 'Competency: ${c.description}',
      if (excerpt != null && excerpt.trim().isNotEmpty)
        'Real material already saved on this device for this exact topic — ground the notes in this '
            'first:\n$excerpt',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Lesson Plan — ${widget.entry.title}'),
        actions: [
          IconButton(
            tooltip: 'AI-enhanced lesson plan',
            onPressed: _generatingAi ? null : _generateWithAi,
            icon: _generatingAi
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.auto_awesome),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          if (_availableTemplates.length > 1) ...[
            DropdownButtonFormField<LessonPlanTemplate>(
              decoration: const InputDecoration(labelText: 'Template', border: OutlineInputBorder()),
              value: _activeTemplate,
              items: [
                for (final t in _availableTemplates) DropdownMenuItem(value: t, child: Text(t.name)),
              ],
              onChanged: _onTemplateChanged,
            ),
            const SizedBox(height: 12),
          ],
          Text(
            'Based on: ${_activeTemplate.source}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 16),
          if (_embeddedMatches.isNotEmpty) ...[
            Card(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _embeddedMatches.length == 1
                          ? 'A real, teacher-submitted lesson plan is available for this topic.'
                          : '${_embeddedMatches.length} real, teacher-submitted lesson plans are available for '
                              'this topic.',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < _embeddedMatches.length; i++)
                          OutlinedButton(
                            onPressed: () => _applyEmbedded(_embeddedMatches[i]),
                            child: Text(
                              _embeddedMatches[i].sequenceLabel ??
                                  (_embeddedMatches.length > 1 ? 'Lesson ${i + 1}' : 'Use this lesson plan'),
                            ),
                          ),
                      ],
                    ),
                    if (_usingEmbedded) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Showing a real, sanitized lesson plan below — not generated.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_relatedMaterials.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_relatedMaterials.length} saved material(s) for ${widget.subjectName} — tap to open '
                      'for reference.',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final item in _relatedMaterials)
                          ActionChip(
                            avatar: const Icon(Icons.description_outlined, size: 16),
                            label: Text(item.title, overflow: TextOverflow.ellipsis),
                            onPressed: () => _openRelatedMaterial(item),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          // "evaluation" (Teacher's/Learners' or Lesson Evaluation) is shown
          // at the very bottom, after Lesson Progression — matching the real
          // templates this app was built from, where those fields are filled
          // in by hand only after the lesson has actually been taught.
          for (final section in _activeTemplate.sections.where((s) => s.id != 'evaluation')) ...[
            Text(section.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final field in section.fields) _buildField(field),
            const SizedBox(height: 16),
          ],
          if (_draft.progression.isNotEmpty) ...[
            Text('Lesson Progression', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Fixed stage order from the template — filled in per stage below.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _draft.progression.length; i++) _buildProgressionCard(i),
            const SizedBox(height: 8),
            Text('Resume Lesson', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              "Didn't finish teaching this? Mark the stage you reached and save — opening this lesson "
              'again will offer to continue from there.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _draft.progression.length; i++)
                  ChoiceChip(
                    label: Text(_draft.progression[i].stage),
                    selected: _reachedStageIndex == i,
                    onSelected: (_) => setState(() => _reachedStageIndex = i),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _reachedStageIndex == null ? null : _saveCheckpoint,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Save progress here'),
            ),
          ],
          for (final section in _activeTemplate.sections.where((s) => s.id == 'evaluation')) ...[
            const SizedBox(height: 16),
            Text(section.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final field in section.fields) _buildField(field),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.description_outlined),
            label: const Text('Export & Share (Word)'),
          ),
        ),
      ),
    );
  }

  Widget _buildField(LessonPlanFieldDef field) {
    if (field.autoFilled) {
      final value = _controllers[field.id]!.text;
      if (value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style,
            children: [
              TextSpan(text: '${field.label}: ', style: const TextStyle(fontWeight: FontWeight.bold)),
              TextSpan(text: value),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: _controllers[field.id],
        maxLines: field.type == LessonPlanFieldType.multiline ? 4 : 1,
        decoration: InputDecoration(
          labelText: field.required ? '${field.label} *' : field.label,
          helperText: field.helpText,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildProgressionCard(int index) {
    final stage = _draft.progression[index].stage;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(stage, style: Theme.of(context).textTheme.titleSmall),
                ),
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    controller: _controllers['progression_${index}_duration'],
                    decoration: const InputDecoration(labelText: 'Duration', isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_teacher'],
              maxLines: 3,
              decoration: const InputDecoration(labelText: "Teacher's Role", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_learners'],
              maxLines: 3,
              decoration: const InputDecoration(labelText: "Learners' Role", border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _controllers['progression_${index}_assessment'],
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Assessment Criteria', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
    );
  }
}
