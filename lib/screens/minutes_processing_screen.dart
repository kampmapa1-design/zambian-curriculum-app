import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'dart:io';

import '../models/minutes_session.dart';
import '../services/entitlement_service.dart';
import '../services/minutes_document_service.dart';
import '../services/minutes_reconstruction_service.dart';
import '../services/minutes_session_repository.dart';
import '../services/rewarded_ad_service.dart';
import '../services/school_service.dart';
import '../services/staffroom_service.dart';
import '../services/teacher_profile_repository.dart';
import 'document_pages_capture_screen.dart';

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
  String? _schoolId;
  bool _postedToStaffroom = false;

  /// "Matters Arising" cross-check (2026-09-28, per explicit request): real
  /// photos of the previous meeting's own minutes, captured via
  /// [_confirmAndStart]'s yes/no prompt — null until/unless the teacher
  /// says yes and actually captures something.
  List<File>? _previousMinutesPages;

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
    _loadSchool();
  }

  Future<void> _loadSchool() async {
    final claim = await SchoolService().currentSchoolClaim();
    if (mounted) setState(() => _schoolId = claim.schoolId);
  }

  /// Stage 11 of School Network (added 2026-09-13) — "an optional 'Post to
  /// Staffroom' action when a Minutes Maker document... is finished." A
  /// text summary card, not a clickable file link — the generated DOCX/PDF
  /// only ever exists on this device (there's no existing feature that
  /// uploads it anywhere shareable-by-URL), so a real "link" would need
  /// inventing file hosting this app doesn't have; posting the meeting's
  /// own title/date is the honest version of "summary card" available
  /// with what already exists.
  Future<void> _postToStaffroom() async {
    final schoolId = _schoolId;
    final result = _result;
    if (schoolId == null || result == null) return;
    final profile = await TeacherProfileRepository().load();
    await StaffroomService().post(
      schoolId: schoolId,
      topic: 'General',
      authorName: profile.name,
      text: '📋 Minutes ready: "${result.meetingTitle}" (${widget.session.meetingDate.toLocal().toString().split(' ').first}) — generated via Minutes Maker.',
    );
    if (!mounted) return;
    setState(() => _postedToStaffroom = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Posted to Staffroom.')));
  }

  bool get _entitled => EntitlementService.instance.adGateBypassed;
  int get _totalSteps => (_entitled ? 0 : MinutesProcessingScreen.kRequiredAds) + 1;
  int get _completedSteps => (_entitled ? 0 : _adsCompleted) + (_processingDone ? 1 : 0);
  double get _progress => _totalSteps == 0 ? 0 : _completedSteps / _totalSteps;

  String get _statusLabel {
    if (_completedSteps == 0) return 'Preparing your minutes…';
    if (_completedSteps < _totalSteps) return 'Almost ready…';
    return 'Ready!';
  }

  /// "Matters Arising" cross-check (2026-09-28, per explicit request): asked
  /// once, right before AI processing begins, never silently assumed either
  /// way. A "No" (or backing out of the capture screen without keeping any
  /// pages) proceeds with [_previousMinutesPages] left null — the server
  /// then falls back to scanning the new meeting's own notes for
  /// self-contained references to past matters only, per
  /// buildGenerateMinutesPrompt's own no-previous-minutes mode.
  Future<void> _confirmAndStart() async {
    final hasPrevious = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Previous meeting\'s minutes?'),
        content: const Text(
          'Do you have the previous meeting\'s minutes available to reference? '
          'If so, Smart Teacher can check whether items from that meeting were '
          'addressed in this one.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes')),
        ],
      ),
    );
    if (!mounted) return;

    if (hasPrevious == true) {
      final captured = await Navigator.of(context).push<List<File>?>(
        MaterialPageRoute(
          builder: (_) => const DocumentPagesCaptureScreen(
            title: "Capture Previous Meeting's Minutes",
            instructions: 'Photograph the previous meeting\'s minutes, page by page — '
                'used only to check which of its items this meeting addressed.',
          ),
        ),
      );
      if (!mounted) return;
      if (captured != null && captured.isNotEmpty) {
        setState(() => _previousMinutesPages = captured);
      }
    }

    await _start();
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

    final processingFuture = _reconstructionService
        .reconstruct(pageFiles, previousMinutesPageFiles: _previousMinutesPages)
        .then(
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
              onPressed: _confirmAndStart,
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
            if (_previousMinutesPages != null) ...[
              const SizedBox(height: 4),
              Text(
                'Cross-checking against the previous meeting\'s minutes…',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
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
            if (_schoolId != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _postedToStaffroom ? null : _postToStaffroom,
                icon: const Icon(Icons.forum_outlined),
                label: Text(_postedToStaffroom ? 'Posted to Staffroom' : 'Post to Staffroom'),
              ),
            ],
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
