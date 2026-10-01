import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/national_exam_timetable.dart';
import '../services/national_exam_timetable_service.dart';

/// "Fix 6" (owner request, 2026-09-29) — "Official Timetable Upload"
/// ingestion screen for the national exam timetable's own start (and, as
/// of the same-day refinement, end) date, which gates the learner-facing
/// "Countdown to [year] National Exams?" option and its "Examinations In
/// Progress" state. This is one shared, global date every learner
/// nationwide would see, so writing it is gated to the app owner OR a
/// school's own leadership/administrator with a real Institutional
/// subscription — widened from owner-only the same day, per explicit
/// request ("an administrator account with full institutional
/// subscription"). See [NationalExamTimetableService]'s own doc comment
/// for the full extract-then-review-then-save flow this screen drives, and
/// [NationalExamTimetableAccess] for exactly who qualifies.
class NationalExamTimetableAdminScreen extends StatefulWidget {
  const NationalExamTimetableAdminScreen({super.key, this.service});

  final NationalExamTimetableService? service;

  @override
  State<NationalExamTimetableAdminScreen> createState() => _NationalExamTimetableAdminScreenState();
}

class _NationalExamTimetableAdminScreenState extends State<NationalExamTimetableAdminScreen> {
  late final NationalExamTimetableService _service = widget.service ?? NationalExamTimetableService();

  bool _loading = true;
  NationalExamTimetableAccess _access = const NationalExamTimetableAccess(isOwner: false, isInstitutionalAdmin: false);
  bool _busy = false;
  NationalExamTimetable? _current;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final access = await _service.checkAccess();
    final current = access.allowed ? await _service.fetch() : null;
    if (!mounted) return;
    setState(() {
      _access = access;
      _current = current;
      _loading = false;
    });
  }

  Future<void> _uploadAndExtract() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png']);
    if (!mounted || result.isEmpty || result.first.path == null) return;
    final file = File(result.first.path!);

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final extracted = await _service.extractStartDate(file);
      if (!mounted) return;
      await _reviewAndConfirm(extracted);
    } on NationalExamTimetableUnavailable catch (e) {
      if (mounted) setState(() => _error = '$e');
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not read this file: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Require a review/confirmation step showing the extracted date before
  /// saving, consistent with the app's 'verify before trusting'
  /// discipline" — never auto-saves. The date is shown editable, not just
  /// read-only: the AI extraction is a first draft, not an authority, same
  /// principle as extractCoverPageFields elsewhere in this app.
  Future<void> _reviewAndConfirm(ExtractedExamStartDate extracted) async {
    var picked = extracted.startDate;
    var pickedEnd = extracted.endDate;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setSheet) => AlertDialog(
          title: const Text('Confirm exam dates'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!extracted.found)
                const Text(
                  "The AI couldn't find a clear start date on this document — enter it manually below.",
                  style: TextStyle(fontWeight: FontWeight.bold),
                )
              else ...[
                Text(extracted.examName.isEmpty ? 'Exam timetable' : extracted.examName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('Read from the document — check this is correct before saving:'),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(picked == null ? 'Pick the start date' : '${picked!.day}/${picked!.month}/${picked!.year}'),
                onPressed: () async {
                  final selected = await showDatePicker(
                    context: dialogContext,
                    initialDate: picked ?? DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                  );
                  if (selected != null) setSheet(() => picked = selected);
                },
              ),
              const SizedBox(height: 8),
              if (!extracted.foundEnd)
                const Text(
                  "The AI couldn't find a clear end date — optional, but pick it below so the countdown knows "
                  'when to stop showing "Examinations In Progress".',
                  style: TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_busy_outlined),
                label: Text(pickedEnd == null
                    ? 'Pick the end date (optional)'
                    : '${pickedEnd!.day}/${pickedEnd!.month}/${pickedEnd!.year}'),
                onPressed: () async {
                  final selected = await showDatePicker(
                    context: dialogContext,
                    initialDate: pickedEnd ?? picked ?? DateTime.now(),
                    firstDate: picked ?? DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                  );
                  if (selected != null) setSheet(() => pickedEnd = selected);
                },
              ),
              if (pickedEnd != null)
                TextButton(
                  onPressed: () => setSheet(() => pickedEnd = null),
                  child: const Text('Clear end date'),
                ),
              if (extracted.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('AI note: ${extracted.notes}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(
              onPressed: picked == null ? null : () => Navigator.of(dialogContext).pop(true),
              child: const Text('Confirm & Save'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service.save(
        year: picked!.year,
        startDate: picked!,
        endDate: pickedEnd,
        schoolId: _access.isOwner ? null : _access.schoolId,
      );
      final refreshed = await _service.fetch();
      if (!mounted) return;
      setState(() {
        _current = refreshed;
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved — the countdown is now available to every learner.')),
      );
    } on NationalExamTimetableUnavailable catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('National Exam Timetable')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_access.allowed
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'This tool sets one shared date every learner nationwide would see, so it is restricted to '
                      "the app owner, or a school's own leadership/administrator once that school has an "
                      'Institutional subscription.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Current setting', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 8),
                            if (_current == null)
                              const Text("Not set yet — the learner-facing countdown stays disabled until it is.")
                            else
                              Text(
                                '${_current!.year} exams start ${_current!.startDate.day}/${_current!.startDate.month}/'
                                '${_current!.startDate.year}'
                                '${_current!.endDate == null ? '' : ' and end ${_current!.endDate!.day}/${_current!.endDate!.month}/${_current!.endDate!.year}'}'
                                '\nLast updated ${_current!.updatedAt.toLocal()}',
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Upload a soft copy (PDF or photo) of the real, official national exam timetable. The AI '
                      "reads the exam period's start date, and its end date if visible — nothing else — and you "
                      'confirm both before anything is saved.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : _uploadAndExtract,
                      icon: _busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.upload_file_outlined),
                      label: Text(_busy ? 'Working…' : 'Official Timetable Upload'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
    );
  }
}
