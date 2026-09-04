import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/scheme_of_work.dart';
import '../models/slide_outline.dart';
import '../models/syllabus_models.dart';
import '../services/offline_slide_outline_service.dart';
import '../services/offline_teaching_notes_service.dart';
import '../services/pptx_document_service.dart';
import '../services/slide_outline_ai_service.dart';
import '../services/subject_content_repository.dart';
import '../services/teaching_notes_document_service.dart';
import '../services/teaching_notes_service.dart';
import '../utils/text_utils.dart';

/// Opens the teaching-notes generator for one scheme-of-work entry. Shows
/// notes composed offline from syllabus data immediately (free, no network),
/// with an optional "Research" step behind a button that calls the
/// `generateTeachingNotes` Cloud Function (Gemini-backed) for a fuller,
/// AI-composed version — needs a live connection, so it's offered but not
/// relied on.
///
/// [template] (subject/grade/curriculum) travels alongside [entry] from
/// here on — real, reported bug fixed 2026-09-03: the AI call used to be
/// given only a topic/sub-topic name with no subject attached, which let it
/// drift into writing about a different subject's version of a
/// similarly-named topic. See [_syllabusContext] and [_TeachingNotesSheetState._tryAiVersion].
///
/// [initialFormat] pre-selects 'bullet' (bulletin) or 'paragraph' (essay) —
/// matching the bulletin/essay/slide choice offered right after a topic is
/// picked. [autoGenerateSlides] immediately builds and shares the slide
/// deck when the sheet opens, for the "slide" choice — the sheet still
/// opens underneath so the notes themselves remain visible and shareable.
Future<void> showTeachingNotesSheet(
  BuildContext context, {
  required SchemeOfWorkEntry entry,
  required SyllabusTemplate template,
  String initialFormat = 'bullet',
  bool autoGenerateSlides = false,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TeachingNotesSheet(
      entry: entry,
      template: template,
      initialFormat: initialFormat,
      autoGenerateSlides: autoGenerateSlides,
    ),
  );
}

String _syllabusContext(SchemeOfWorkEntry entry, SyllabusTemplate template) {
  final lines = <String>[
    'Subject: ${template.subject.name}',
    'Grade/Form: ${template.grade.name}',
    'Topic: ${entry.topic.name}',
    if (entry.topic.description != null) entry.topic.description!,
    if (entry.subTopic != null) 'Sub-topic: ${entry.subTopic!.name}',
    if (entry.subTopic?.description != null) entry.subTopic!.description!,
    for (final o in entry.objectives) 'Learning objective: ${o.description}',
    for (final c in entry.competencies) 'Competency: ${c.description}',
  ];
  return lines.join('\n');
}

class _TeachingNotesSheet extends StatefulWidget {
  const _TeachingNotesSheet({
    required this.entry,
    required this.template,
    this.initialFormat = 'bullet',
    this.autoGenerateSlides = false,
  });

  final SchemeOfWorkEntry entry;
  final SyllabusTemplate template;
  final String initialFormat;
  final bool autoGenerateSlides;

  @override
  State<_TeachingNotesSheet> createState() => _TeachingNotesSheetState();
}

class _TeachingNotesSheetState extends State<_TeachingNotesSheet> {
  final _offlineService = OfflineTeachingNotesService();
  final _aiService = TeachingNotesService();
  final _offlineSlideService = OfflineSlideOutlineService();
  final _slideAiService = SlideOutlineAiService();
  final _pptxService = PptxDocumentService();
  final _notesDocumentService = TeachingNotesDocumentService();
  final _subjectContentRepository = SubjectContentRepository();
  String? _subjectContentExcerpt;
  bool _excerptLoadAttempted = false;

  late String _format = widget.initialFormat;
  String _notes = '';
  bool _isAiGenerated = false;
  bool _loadingAi = false;
  String? _aiError;
  bool _generatingSlides = false;
  bool _sharingNotes = false;

  @override
  void initState() {
    super.initState();
    _regenerateOffline();
    if (widget.autoGenerateSlides) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _generateSlides());
    }
  }

  void _regenerateOffline() {
    setState(() {
      _notes = _offlineService.compose(
        entry: widget.entry,
        format: _format,
        subjectContentExcerpt: _subjectContentExcerpt,
      );
      _isAiGenerated = false;
      _aiError = null;
    });
    if (!_excerptLoadAttempted) _loadSubjectContentExcerpt();
  }

  /// Looked up once per sheet, lazily — a Subject Content Database lookup
  /// touches disk for every stored item, so it's worth avoiding when
  /// nothing's stored or nothing matches. Silently does nothing on
  /// failure or when no match is found: this is a "nice to have"
  /// enrichment, never something the notes should visibly depend on.
  ///
  /// Real, reported bug fixed 2026-09-04: this call never passed
  /// [SubjectContentRepository.findRelevantExcerpt]'s own `subjectName`
  /// filter, so it searched every stored subject's content by keyword
  /// overlap alone — a Religious Education search for "Work in a Changing
  /// Society" could match a Geography module's generic front matter
  /// ("How to use this teaching module...") purely on shared common
  /// words, and that wrong-subject text then got handed to the AI as
  /// "real material — ground the notes in this FIRST". LessonPlanScreen's
  /// own excerpt lookup (via SubjectContentIndex.resolve) already passed
  /// subjectName correctly; only this direct call was missing it.
  Future<void> _loadSubjectContentExcerpt() async {
    _excerptLoadAttempted = true;
    try {
      final excerpt = await _subjectContentRepository.findRelevantExcerpt(
        subjectName: widget.template.subject.name,
        topicName: widget.entry.topic.name,
        subTopicName: widget.entry.subTopic?.name,
      );
      if (excerpt == null || !mounted || _isAiGenerated) return;
      setState(() => _subjectContentExcerpt = excerpt);
      if (!_isAiGenerated) _regenerateOffline();
    } catch (_) {
      // Best-effort enrichment — the syllabus-only notes already shown
      // stand on their own.
    }
  }

  Future<void> _tryAiVersion() async {
    setState(() {
      _loadingAi = true;
      _aiError = null;
    });
    try {
      final result = await _aiService.generate(
        topic: widget.entry.topic.name,
        subtopic: widget.entry.subTopic?.name,
        subject: widget.template.subject.name,
        grade: widget.template.grade.name,
        syllabusContext: _syllabusContext(widget.entry, widget.template),
        format: _format,
      );
      if (!mounted) return;
      setState(() {
        // Safety nets: strip any Markdown the model slipped in despite the
        // plain-text instruction, then enforce the 700-word essay cap (AI
        // output can occasionally run over on either).
        final cleaned = stripMarkdownArtifacts(result.notes);
        _notes = _format == 'paragraph'
            ? capWords(cleaned, 700, trailingNote: '(Trimmed to stay within the 700-word essay limit.)')
            : cleaned;
        _isAiGenerated = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiError = 'AI-enhanced notes aren\'t available yet ($e). Showing notes from your '
          'syllabus data instead.');
    } finally {
      if (mounted) setState(() => _loadingAi = false);
    }
  }

  Future<void> _generateSlides() async {
    setState(() => _generatingSlides = true);
    try {
      SlideOutline outline = _offlineSlideService.compose(
        entry: widget.entry,
        notesText: _notes,
        notesFormat: _format,
      );
      try {
        // Best-effort AI enhancement — keeps the offline outline if this
        // fails (no Blaze-plan backend deployed yet, or simply offline),
        // matching "work offline, AI-enhanced when online" rather than
        // blocking slide generation on it.
        outline = await _slideAiService.generate(
          topic: widget.entry.topic.name,
          subtopic: widget.entry.subTopic?.name,
          subject: widget.template.subject.name,
          notesText: _notes,
          notesFormat: _format,
        );
      } catch (_) {
        // Keep the offline outline.
      }
      final file = await _pptxService.generate(outline);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Slides — ${widget.entry.title}',
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the slide deck: $error')),
      );
    } finally {
      if (mounted) setState(() => _generatingSlides = false);
    }
  }

  Future<void> _shareNotes({required bool asDocx}) async {
    setState(() => _sharingNotes = true);
    try {
      final file = asDocx
          ? await _notesDocumentService.generateDocx(title: widget.entry.title, notes: _notes)
          : await _notesDocumentService.generatePdf(title: widget.entry.title, notes: _notes);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        subject: 'Teaching notes — ${widget.entry.title}',
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create the file: $error')),
      );
    } finally {
      if (mounted) setState(() => _sharingNotes = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Teaching notes', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(widget.entry.title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bullet', label: Text('Bullet points')),
                  ButtonSegment(value: 'paragraph', label: Text('Paragraphs')),
                ],
                selected: {_format},
                onSelectionChanged: _loadingAi
                    ? null
                    : (selection) {
                        setState(() => _format = selection.first);
                        if (!_isAiGenerated) _regenerateOffline();
                      },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadingAi ? null : _tryAiVersion,
                icon: _loadingAi
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(_loadingAi ? 'Researching…' : 'Research'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _generatingSlides ? null : _generateSlides,
                icon: _generatingSlides
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.slideshow_outlined),
                label: Text(_generatingSlides ? 'Building slides…' : 'Generate PowerPoint slides'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _sharingNotes ? null : () => _shareNotes(asDocx: true),
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: const Text('Share as Word'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _sharingNotes ? null : () => _shareNotes(asDocx: false),
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: const Text('Share as PDF'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_aiError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_aiError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Text(
                _isAiGenerated ? 'AI-generated' : 'From your syllabus data (offline, free)',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: SelectableText(_notes),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
