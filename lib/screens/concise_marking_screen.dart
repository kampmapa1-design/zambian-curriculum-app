import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import '../services/concise_marking_service.dart';
import '../services/marking_entitlement_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/marking_script_repository.dart';
import '../services/script_annotation_service.dart';

/// "Concise Marking" (Scan Marker, 2026-09-11, per explicit request): AI
/// marking that draws its own real tick (✓) or cross (✗) — plus the marks
/// awarded — directly onto a copy of the actual photographed script page,
/// right at each answer's own real location, rather than only recording
/// marks in a table a teacher has to cross-reference back to the script
/// by hand. Answers the AI can't confidently place fall back to a
/// separately generated "computer generated version" page instead (see
/// ScriptAnnotationService's own doc comment) — never guessed onto the
/// wrong part of a real scanned document.
///
/// Works on any already-captured script that already has a marking
/// scheme linked (queued, graded, or reviewed — not a fresh capture with
/// no scheme chosen yet, since Concise Marking needs the same real
/// question/expected-answer/marks structure normal grading does). Uses
/// the exact same free-tier grading allowance as normal AI marking (see
/// MarkingEntitlementService) — this is still real AI grading, just with
/// an extra, real capability on top, not a separate budget.
class ConciseMarkingScreen extends StatefulWidget {
  const ConciseMarkingScreen({super.key, this.repository, this.schemeRepository, this.gradingService, this.annotationService});

  final MarkingScriptRepository? repository;
  final MarkingSchemeRepository? schemeRepository;
  final ConciseMarkingService? gradingService;
  final ScriptAnnotationService? annotationService;

  @override
  State<ConciseMarkingScreen> createState() => _ConciseMarkingScreenState();
}

class _ConciseMarkingScreenState extends State<ConciseMarkingScreen> {
  late final MarkingScriptRepository _repository = widget.repository ?? MarkingScriptRepository();
  late final MarkingSchemeRepository _schemeRepository = widget.schemeRepository ?? MarkingSchemeRepository();
  late final ConciseMarkingService _gradingService = widget.gradingService ?? ConciseMarkingService();
  late final ScriptAnnotationService _annotationService = widget.annotationService ?? ScriptAnnotationService();

  bool _loading = true;
  String? _loadError;
  List<MarkingScript> _eligibleScripts = [];
  MarkingSchemeCatalog _schemes = MarkingSchemeCatalog.empty();

  MarkingScript? _selected;
  bool _grading = false;
  String? _gradingError;
  List<File>? _annotatedPages;
  File? _fallbackPdf;
  List<String>? _observations;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final catalog = await _repository.loadCatalog();
      final schemes = await _schemeRepository.loadCatalog();
      final eligible = catalog.scripts.where((s) => s.schemeId != null && !s.photosDiscarded).toList()
        ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      if (!mounted) return;
      setState(() {
        _eligibleScripts = eligible;
        _schemes = schemes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load scripts: $error';
        _loading = false;
      });
    }
  }

  MarkingScheme? _schemeFor(MarkingScript script) {
    if (script.schemeId == null) return null;
    for (final s in _schemes.schemes) {
      if (s.id == script.schemeId) return s;
    }
    return null;
  }

  Future<void> _runConciseMarking(MarkingScript script) async {
    final scheme = _schemeFor(script);
    if (scheme == null) {
      setState(() => _gradingError = "This script's own marking scheme could not be found anymore.");
      return;
    }
    if (!await MarkingEntitlementService.instance.canGradeAnother()) {
      setState(() => _gradingError = "You've used this month's free AI gradings — the same allowance normal "
          'marking uses.');
      return;
    }

    setState(() {
      _selected = script;
      _grading = true;
      _gradingError = null;
      _annotatedPages = null;
      _fallbackPdf = null;
      _observations = null;
    });

    try {
      final pageFiles = await _repository.pageFilesFor(script);
      if (pageFiles.isEmpty) {
        throw const ConciseMarkingUnavailable(
          "This script's captured pages are no longer available (they may have already been discarded to free storage).",
        );
      }

      final graded = await _gradingService.grade(pageFiles: pageFiles, scheme: scheme);
      await MarkingEntitlementService.instance.recordGradingUsed();

      final updated = script.copyWith(
        status: MarkingScriptStatus.graded,
        gradedAnswers: graded.answers,
        observations: graded.observations,
      );
      await _repository.update(updated);

      final tempDir = await getTemporaryDirectory();
      final outputDir = Directory('${tempDir.path}/concise_marking_${script.id}');
      if (!await outputDir.exists()) await outputDir.create(recursive: true);

      final annotated = await _annotationService.annotatePages(
        pageFiles: pageFiles,
        answers: graded.answers,
        annotations: graded.annotations,
        outputDir: outputDir,
      );
      final fallback = await _annotationService.generateFallbackReproduction(
        answers: graded.answers,
        annotations: graded.annotations,
        outputDir: outputDir,
        title: '${script.fullName} — ${scheme.title}',
      );

      if (!mounted) return;
      setState(() {
        _grading = false;
        _annotatedPages = annotated;
        _fallbackPdf = fallback;
        _observations = graded.observations;
      });
      _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _grading = false;
        _gradingError = '$error';
      });
    }
  }

  Future<void> _shareResults() async {
    final files = <XFile>[
      for (final f in _annotatedPages ?? const <File>[]) XFile(f.path),
      if (_fallbackPdf case final pdf?) XFile(pdf.path),
    ];
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files, subject: '${_selected?.fullName ?? 'Script'} — Concise Marking'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Concise Marking')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                        const SizedBox(height: 12),
                        Text(_loadError!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _load, child: const Text('Try Again')),
                      ],
                    ),
                  ),
                )
              : _selected != null
                  ? _buildResult(context)
                  : _buildScriptPicker(context),
    );
  }

  Widget _buildScriptPicker(BuildContext context) {
    if (_eligibleScripts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.fact_check_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text(
                'No scripts with a marking scheme linked yet — queue a script against a scheme first, '
                'from Scan Marker\'s own "Upload Script".',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Pick a script to mark with real ticks/crosses drawn on its own photographed pages.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _eligibleScripts.length,
            itemBuilder: (context, index) {
              final script = _eligibleScripts[index];
              final scheme = _schemeFor(script);
              return ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(script.fullName),
                subtitle: Text('${scheme?.title ?? script.subjectName} · ${script.status.label}'),
                onTap: () => _runConciseMarking(script),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context) {
    final selected = _selected!;
    if (_grading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Marking ${selected.fullName}\'s script and locating each answer…', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    if (_gradingError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(_gradingError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(onPressed: () => setState(() => _selected = null), child: const Text('Pick Another')),
                  const SizedBox(width: 12),
                  FilledButton(onPressed: () => _runConciseMarking(selected), child: const Text('Try Again')),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final annotated = _annotatedPages ?? const <File>[];
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${selected.fullName} — marked', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                annotated.isEmpty
                    ? "No answer could be confidently placed on the actual photo — see the generated page below instead."
                    : '${annotated.length} page(s) marked directly on the real photographed script.'
                        '${_fallbackPdf != null ? ' Some answers couldn\'t be confidently placed, so those are marked on a separately generated page instead.' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (final page in annotated)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(page),
                  ),
                ),
              if (_fallbackPdf != null)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('Answers marked on a generated page'),
                    subtitle: Text('For the answers not confidently locatable on the real photo'),
                  ),
                ),
              if (_observations case final obs? when obs.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Observations', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final o in obs) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('•  $o')),
              ],
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _selected = null),
                    child: const Text('Pick Another Script'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (annotated.isEmpty && _fallbackPdf == null) ? null : _shareResults,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
