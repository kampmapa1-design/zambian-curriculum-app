import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/home_assignment.dart';
import '../models/marking_scheme.dart';
import '../models/school.dart';
import '../services/concise_marking_service.dart';
import '../services/home_assignment_service.dart';
import 'document_pages_capture_screen.dart';
import 'home_assignment_batch_review_screen.dart';

enum _ImportSource { camera, device }
enum _MarkingEngine { concise, stable }

/// Home Assignment epic, Stages 8-10 — the submission queue for one
/// assignment: in-app submissions arrive here automatically (Stage 8),
/// Stage 9's bulk import adds externally-received photos alongside them
/// with no visible difference once queued, and Stage 10's batch controls
/// mark a chosen number of QUEUED submissions in one go, reusing
/// `ConciseMarkingService` exactly (Stable = `lightweight: true`) —
/// no new marking engine, no "Uploaded Key" option (the key IS this
/// assignment's own, always authoritative here).
class HomeAssignmentQueueScreen extends StatefulWidget {
  const HomeAssignmentQueueScreen({required this.school, required this.schoolClass, required this.assignment, super.key});
  final School school;
  final SchoolClass schoolClass;
  final IssuedHomeAssignment assignment;

  @override
  State<HomeAssignmentQueueScreen> createState() => _HomeAssignmentQueueScreenState();
}

class _HomeAssignmentQueueScreenState extends State<HomeAssignmentQueueScreen> {
  final _service = HomeAssignmentService();
  final _markingService = ConciseMarkingService();
  bool _importing = false;
  bool _marking = false;
  String _markingStatus = '';

  // "Once new items exist in an assignment's queue, show the teacher:
  // 'Mark received home assignments using their marking key?'" (2026-09-16,
  // per explicit request). Last-seen queued count is per-assignment,
  // on-device only (SharedPreferences) — no server round-trip needed for
  // what's purely a "did this screen already tell you about these" flag.
  // `_askedThisOpen` guards against the dialog re-firing on every
  // `watchSubmissions` tick; it resets only by reopening the screen.
  static const _lastSeenQueuedCountPrefsPrefix = 'home_assignment_last_seen_queued_';
  bool _askedThisOpen = false;
  int? _lastSeenQueuedCount;

  @override
  void initState() {
    super.initState();
    _loadLastSeenQueuedCount();
  }

  Future<void> _loadLastSeenQueuedCount() async {
    final prefs = await SharedPreferences.getInstance();
    final count = prefs.getInt('$_lastSeenQueuedCountPrefsPrefix${widget.assignment.id}') ?? 0;
    if (mounted) setState(() => _lastSeenQueuedCount = count);
  }

  Future<void> _storeLastSeenQueuedCount(int count) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('$_lastSeenQueuedCountPrefsPrefix${widget.assignment.id}', count);
  }

  /// Fires the "mark now?" prompt at most once per screen-open, only when
  /// the live queue has grown past what this screen last recorded. Runs
  /// from the `StreamBuilder`'s builder, so the store-and-dialog happens
  /// after the frame (`addPostFrameCallback`) rather than mid-build.
  void _maybeOfferBatchMarking(List<HomeAssignmentSubmission> queued) {
    final lastSeen = _lastSeenQueuedCount;
    if (lastSeen == null || _askedThisOpen) return; // not loaded yet, or already asked
    if (queued.isEmpty || queued.length <= lastSeen) return;
    _askedThisOpen = true;
    unawaited(_storeLastSeenQueuedCount(queued.length));
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerBatchMarking(queued));
  }

  Future<void> _offerBatchMarking(List<HomeAssignmentSubmission> queued) async {
    if (!mounted) return;
    final markNow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New submissions'),
        content: const Text('Mark received home assignments using their marking key?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes')),
        ],
      ),
    );
    if (markNow == true && mounted) await _startBatchMarking(queued);
  }

  Future<void> _importSubmission() async {
    final learnerName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Import submission for'),
        children: [
          for (final name in widget.schoolClass.learnerNames)
            SimpleDialogOption(onPressed: () => Navigator.of(dialogContext).pop(name), child: Text(name)),
        ],
      ),
    );
    if (learnerName == null || !mounted) return;

    final source = await showDialog<_ImportSource>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Import from'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.of(dialogContext).pop(_ImportSource.camera), child: const Text('Camera')),
          SimpleDialogOption(onPressed: () => Navigator.of(dialogContext).pop(_ImportSource.device), child: const Text('Device (photo already received via WhatsApp/email)')),
        ],
      ),
    );
    if (source == null || !mounted) return;

    List<File> files;
    if (source == _ImportSource.camera) {
      final captured = await Navigator.of(context).push<List<File>>(
        MaterialPageRoute(builder: (_) => DocumentPagesCaptureScreen(title: 'Capture $learnerName\'s Answers', instructions: "Photograph each page of $learnerName's answers.")),
      );
      if (captured == null || captured.isEmpty || !mounted) return;
      files = captured;
    } else {
      final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
      if (result.isEmpty || !mounted) return;
      final picked = <File>[];
      for (final f in result) {
        if (f.path != null) picked.add(File(f.path!));
      }
      if (picked.isEmpty) return;
      files = picked;
    }

    setState(() => _importing = true);
    try {
      final uid = 'import_${DateTime.now().millisecondsSinceEpoch}';
      final paths = <String>[];
      for (var i = 0; i < files.length; i++) {
        final bytes = await files[i].readAsBytes();
        final path = await _service.uploadSubmissionPhoto(
          schoolId: widget.school.id,
          classId: widget.schoolClass.id,
          assignmentId: widget.assignment.id,
          uploaderUid: uid,
          index: i,
          bytes: bytes,
        );
        paths.add(path);
      }
      await _service.recordSubmission(
        schoolId: widget.school.id,
        classId: widget.schoolClass.id,
        assignmentId: widget.assignment.id,
        photoPaths: paths,
        learnerName: learnerName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$learnerName's submission imported.")));
    } on HomeAssignmentException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _startBatchMarking(List<HomeAssignmentSubmission> queued) async {
    final choice = await showDialog<({_MarkingEngine engine, int batchSize})>(
      context: context,
      builder: (_) => _BatchMarkingDialog(maxAvailable: queued.length),
    );
    if (choice == null || !mounted) return;

    final batch = queued.take(choice.batchSize).toList();
    setState(() {
      _marking = true;
      _markingStatus = 'Starting...';
    });

    final scheme = MarkingScheme(
      id: 'home_assignment_${widget.assignment.id}',
      title: widget.assignment.markingKeyTitle,
      subjectName: widget.assignment.subjectName,
      gradeName: widget.schoolClass.classGrade,
      topicName: widget.assignment.title,
      questions: widget.assignment.toMarkingSchemeQuestions(),
      createdAt: DateTime.now(),
    );

    final markedIds = <String>[];
    var failures = 0;
    for (var i = 0; i < batch.length; i++) {
      final submission = batch[i];
      if (mounted) setState(() => _markingStatus = 'Marking ${i + 1} of ${batch.length} (${submission.learnerName})...');
      try {
        final tempDir = await getTemporaryDirectory();
        final pageFiles = <File>[];
        for (var p2 = 0; p2 < submission.photoPaths.length; p2++) {
          final bytes = await _service.downloadSubmissionPhoto(submission.photoPaths[p2]);
          final file = File(p.join(tempDir.path, 'ha_${submission.id}_$p2.jpg'));
          await file.writeAsBytes(bytes, flush: true);
          pageFiles.add(file);
        }
        final result = await _markingService.grade(pageFiles: pageFiles, scheme: scheme, lightweight: choice.engine == _MarkingEngine.stable);
        final score = result.answers.fold<double>(0, (sum, a) => sum + a.marksAwarded);
        final maxScore = result.answers.fold<double>(0, (sum, a) => sum + a.maxMarks);
        await _service.recordMarkingResult(
          schoolId: widget.school.id,
          classId: widget.schoolClass.id,
          assignmentId: widget.assignment.id,
          submissionId: submission.id,
          score: score,
          maxScore: maxScore,
          answers: [
            for (final a in result.answers)
              {'questionLabel': a.questionLabel, 'transcribedAnswer': a.transcribedAnswer, 'marksAwarded': a.marksAwarded, 'maxMarks': a.maxMarks, 'confidence': a.confidence.name},
          ],
          markingEngine: choice.engine == _MarkingEngine.stable ? 'stable' : 'concise',
        );
        markedIds.add(submission.id);
      } catch (e) {
        failures++;
      }
    }

    if (!mounted) return;
    setState(() {
      _marking = false;
      _markingStatus = '';
    });
    if (failures > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failures submission(s) could not be marked — try them again individually.')));
    }
    if (markedIds.isNotEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HomeAssignmentBatchReviewScreen(school: widget.school, schoolClass: widget.schoolClass, assignment: widget.assignment, submissionIds: markedIds),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.assignment.referenceCode;
    return Scaffold(
      appBar: AppBar(title: Text(widget.assignment.title)),
      body: StreamBuilder<List<HomeAssignmentSubmission>>(
        stream: _service.watchSubmissions(widget.school.id, widget.schoolClass.id, widget.assignment.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final submissions = snapshot.data!;
          final queued = submissions.where((s) => s.status == HomeAssignmentSubmissionStatus.queued).toList();
          final marked = submissions.where((s) => s.status == HomeAssignmentSubmissionStatus.marked).toList();
          final sent = submissions.where((s) => s.status == HomeAssignmentSubmissionStatus.sent).toList();
          _maybeOfferBatchMarking(queued);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Reference code is how a teacher cross-checks a WhatsApp
              // message against the right assignment — the whole reason
              // this field exists (2026-09-16). Only null for an
              // assignment sent before the field did.
              if (code != null) ...[
                Chip(avatar: const Icon(Icons.tag, size: 16), label: Text('Reference code: $code', style: const TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.upload_file_outlined),
                      label: Text(_importing ? 'Importing...' : 'Import Submission (camera/WhatsApp/device)'),
                      onPressed: _importing ? null : _importSubmission,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text('Queued (${queued.length})', style: Theme.of(context).textTheme.titleSmall),
              if (queued.isNotEmpty) ...[
                const SizedBox(height: 4),
                if (_marking)
                  Card(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)), const SizedBox(width: 12), Expanded(child: Text(_markingStatus))])))
                else
                  FilledButton.icon(icon: const Icon(Icons.auto_awesome_outlined), label: const Text('Mark Batch'), onPressed: () => _startBatchMarking(queued)),
              ],
              for (final s in queued) _submissionTile(s),
              const SizedBox(height: 16),
              Text('Marked, not yet sent (${marked.length})', style: Theme.of(context).textTheme.titleSmall),
              for (final s in marked) _submissionTile(s),
              const SizedBox(height: 16),
              Text('Sent (${sent.length})', style: Theme.of(context).textTheme.titleSmall),
              for (final s in sent) _submissionTile(s),
            ],
          );
        },
      ),
    );
  }

  // 'app' = pupil's own in-app submission, 'imported' = teacher manually
  // imported a photo (camera or device — the device pick IS the WhatsApp
  // path, since that's exactly how a WhatsApp-received photo gets in),
  // 'email' = auto-ingested by the Gmail-polling Cloud Function
  // (2026-09-16). Unknown values fall back to the 'app' look rather than
  // erroring, matching HomeAssignmentSubmission.fromMap's own default.
  IconData _sourceIcon(String submittedVia) => switch (submittedVia) {
        'imported' => Icons.upload_file_outlined,
        'email' => Icons.email_outlined,
        _ => Icons.smartphone,
      };

  String _sourceLabel(String submittedVia) => switch (submittedVia) {
        'imported' => 'Imported (camera/WhatsApp)',
        'email' => 'Emailed in',
        _ => 'Submitted via app',
      };

  Widget _submissionTile(HomeAssignmentSubmission s) {
    return Card(
      child: ListTile(
        leading: Icon(_sourceIcon(s.submittedVia)),
        title: Text(s.learnerName),
        subtitle: Text(
          s.score != null
              ? '${s.score!.toStringAsFixed(0)} / ${s.maxScore!.toStringAsFixed(0)} · ${_sourceLabel(s.submittedVia)}${s.hasLowConfidence ? ' · needs review' : ''}'
              : _sourceLabel(s.submittedVia),
        ),
        trailing: s.hasLowConfidence && s.status != HomeAssignmentSubmissionStatus.queued ? const Icon(Icons.flag_outlined, color: Colors.orange) : null,
      ),
    );
  }
}

class _BatchMarkingDialog extends StatefulWidget {
  const _BatchMarkingDialog({required this.maxAvailable});
  final int maxAvailable;

  @override
  State<_BatchMarkingDialog> createState() => _BatchMarkingDialogState();
}

class _BatchMarkingDialogState extends State<_BatchMarkingDialog> {
  _MarkingEngine _engine = _MarkingEngine.concise;
  int? _batchSize = 5;
  final _customController = TextEditingController();

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mark Batch'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.maxAvailable} queued.', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          const Text('Marking engine'),
          RadioListTile<_MarkingEngine>(
            dense: true,
            title: const Text('Concise Marker'),
            value: _MarkingEngine.concise,
            groupValue: _engine,
            onChanged: (v) => setState(() => _engine = v!),
          ),
          RadioListTile<_MarkingEngine>(
            dense: true,
            title: const Text('Stable Marker'),
            value: _MarkingEngine.stable,
            groupValue: _engine,
            onChanged: (v) => setState(() => _engine = v!),
          ),
          const SizedBox(height: 8),
          const Text('Batch size'),
          Wrap(
            spacing: 8,
            children: [
              for (final size in [5, 10, 20, 40])
                ChoiceChip(label: Text('$size'), selected: _batchSize == size, onSelected: (_) => setState(() => _batchSize = size)),
              ChoiceChip(label: const Text('Custom'), selected: _batchSize == null, onSelected: (_) => setState(() => _batchSize = null)),
            ],
          ),
          if (_batchSize == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(controller: _customController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Custom batch size', border: OutlineInputBorder())),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final size = _batchSize ?? int.tryParse(_customController.text.trim());
            if (size == null || size <= 0) return;
            Navigator.of(context).pop((engine: _engine, batchSize: size.clamp(1, widget.maxAvailable)));
          },
          child: const Text('Start'),
        ),
      ],
    );
  }
}
