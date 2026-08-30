import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/minutes_session.dart';
import '../services/entitlement_service.dart';
import '../services/minutes_document_service.dart';
import '../services/minutes_reconstruction_service.dart';
import '../services/minutes_session_repository.dart';
import '../services/rewarded_ad_service.dart';

/// Minutes Maker, Stages 6-8 — the ad-gate, the unified ad+processing
/// progress experience, and export. Kept as one screen (not three)
/// because they're genuinely one continuous user experience: watch ads
/// while your notes are being read, then download.
class MinutesProcessingScreen extends StatefulWidget {
  const MinutesProcessingScreen({
    super.key,
    required this.session,
    this.repository,
    this.reconstructionService,
    this.documentService,
  });

  static const kRequiredAds = 4;

  final MinutesSession session;
  final MinutesSessionRepository? repository;
  final MinutesReconstructionService? reconstructionService;
  final MinutesDocumentService? documentService;

  @override
  State<MinutesProcessingScreen> createState() => _MinutesProcessingScreenState();
}

enum _Stage { intro, running, ready, error }

class _MinutesProcessingScreenState extends State<MinutesProcessingScreen> {
  late final MinutesSessionRepository _repository = widget.repository ?? MinutesSessionRepository();
  late final MinutesReconstructionService _reconstructionService =
      widget.reconstructionService ?? MinutesReconstructionService();
  late final MinutesDocumentService _documentService = widget.documentService ?? MinutesDocumentService();

  late _Stage _stage;
  String? _errorMessage;

  int _adsCompleted = 0;
  bool _processingDone = false;
  ReconstructedMinutes? _result;

  @override
  void initState() {
    super.initState();
    // Already processed earlier (re-opened from the queue) — go straight
    // to the download options rather than re-running ads/AI for free.
    final sections = widget.session.sections;
    if (widget.session.status == MinutesSessionStatus.ready && sections != null) {
      _result = ReconstructedMinutes(meetingTitle: widget.session.meetingTitle, sections: sections, notes: '');
      _stage = _Stage.ready;
    } else {
      _stage = _Stage.intro;
    }
  }

  bool get _entitled => EntitlementService.instance.hasLocalEntitlement;
  int get _totalSteps => (_entitled ? 0 : MinutesProcessingScreen.kRequiredAds) + 1;
  int get _completedSteps => (_entitled ? 0 : _adsCompleted) + (_processingDone ? 1 : 0);
  double get _progress => _totalSteps == 0 ? 0 : _completedSteps / _totalSteps;

  String get _statusLabel {
    if (_completedSteps == 0) return 'Preparing your minutes…';
    if (_completedSteps < _totalSteps) return 'Almost ready…';
    return 'Ready!';
  }

  Future<void> _start() async {
    setState(() {
      _stage = _Stage.running;
      _adsCompleted = 0;
      _processingDone = false;
      _errorMessage = null;
    });

    final pageFiles = await _repository.pageFilesFor(widget.session);

    // Ads and processing run concurrently — Stage 7's "in parallel"
    // requirement — each reporting into the same combined progress state.
    final adsFuture = _entitled
        ? Future.value(true)
        : RewardedAdService.instance.showAds(
            count: MinutesProcessingScreen.kRequiredAds,
            onProgress: (completed, total) {
              if (!mounted) return;
              setState(() => _adsCompleted = completed);
            },
          );

    final processingFuture = _reconstructionService.reconstruct(pageFiles).then(
      (result) {
        if (!mounted) return result;
        setState(() => _processingDone = true);
        return result;
      },
      onError: (Object error) {
        if (mounted) setState(() => _errorMessage = 'Could not process these notes: $error');
        throw error;
      },
    );

    bool adsWatched;
    ReconstructedMinutes? reconstructed;
    try {
      // Wait for both, but don't let one's failure hide the other's error —
      // gather both outcomes before deciding what to show.
      final results = await Future.wait<Object?>([adsFuture, processingFuture], eagerError: false);
      adsWatched = results[0] as bool;
      reconstructed = results[1] as ReconstructedMinutes?;
    } catch (_) {
      adsWatched = false;
      reconstructed = null;
    }

    if (!mounted) return;

    if (!adsWatched) {
      setState(() {
        _stage = _Stage.error;
        _errorMessage ??= "The ad wasn't watched to completion, so this stays locked. Try again when you can "
            'watch all $_totalSteps steps without interruption.';
      });
      return;
    }
    if (reconstructed == null) {
      setState(() => _stage = _Stage.error);
      return;
    }

    final updated = widget.session.copyWith(status: MinutesSessionStatus.ready, sections: reconstructed.sections);
    await _repository.update(updated);

    if (!mounted) return;
    setState(() {
      _result = reconstructed;
      _stage = _Stage.ready;
    });
  }

  Future<void> _download(bool asPdf) async {
    final result = _result;
    if (result == null) return;
    final file = asPdf
        ? await _documentService.generatePdf(result, widget.session.meetingDate)
        : await _documentService.generateDocx(result, widget.session.meetingDate);
    if (!mounted) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: result.meetingTitle));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.session.meetingTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_stage) {
      case _Stage.intro:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_awesome_outlined, size: 56),
            const SizedBox(height: 16),
            Text('${widget.session.pageCount} page(s) of notes, ready to process.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            if (!_entitled) ...[
              const Text(
                'Smart Teacher runs on ads and subscriptions to stay free/affordable — please watch these '
                'short videos to unlock your minutes.',
                textAlign: TextAlign.center,
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 8),
              Text(
                '${MinutesProcessingScreen.kRequiredAds} short ads, watched one after another, while your '
                'notes are being processed in the background.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
            ] else
              const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.play_circle_outline),
              label: Text(_entitled ? 'Generate Minutes' : 'Watch ads & generate minutes'),
            ),
          ],
        );
      case _Stage.running:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 72,
              height: 72,
              child: CircularProgressIndicator(value: _progress == 0 ? null : _progress, strokeWidth: 6),
            ),
            const SizedBox(height: 20),
            Text(_statusLabel, style: Theme.of(context).textTheme.titleMedium),
            if (!_entitled) ...[
              const SizedBox(height: 8),
              Text(
                'Ad $_adsCompleted of ${MinutesProcessingScreen.kRequiredAds} watched'
                '${_processingDone ? ' · notes processed' : ' · processing your notes…'}',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        );
      case _Stage.ready:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 56),
            const SizedBox(height: 16),
            Text(_result?.meetingTitle ?? '', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => _download(true),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Download as PDF'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _download(false),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Download as Word'),
            ),
          ],
        );
      case _Stage.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(_errorMessage ?? 'Something went wrong.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => setState(() => _stage = _Stage.intro), child: const Text('Try again')),
          ],
        );
    }
  }
}
