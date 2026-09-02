import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/pending_marking_key_draft_repository.dart';
import '../services/subject_content_extraction_service.dart';
import 'document_pages_capture_screen.dart';
import 'marking_key_details_form_screen.dart';
import 'marking_scheme_builder_screen.dart';

enum MarkingKeyUploadMethod { uploadFromDevice, camera }

/// Stage B — the full "AI, read this marking key/question paper for me"
/// flow: device-or-camera → Gemini → confirmation → manual Subject/Level/
/// Exam-type entry → MarkingSchemeBuilderScreen (pre-filled, always
/// reviewed, never auto-saved — see the Cloud Function's own comment for
/// why a question paper especially can't just be trusted directly).
/// Shared by MarkingSchemeListScreen's "New Scheme" flow and the AI-
/// Assisted Marking hub's direct "Upload Marking Key" button so both go
/// through identical behavior rather than two copies drifting apart.
///
/// **2026-08-29**: previously this asked for subject/grade/topic via the
/// app's bundled-syllabus PICKER, one topic at a time. Real complaint: a
/// full mock exam or past paper doesn't map to a single topic, and the
/// picker felt disconnected from what was actually just uploaded ("loses
/// track"). Replaced with a plain manual-entry form (subject name, level,
/// type of exam — see MarkingKeyDetailsFormScreen) — no dropdown at all
/// for this flow now.
///
/// **2026-08-29, same day**: also now saves the AI's derived result to
/// disk (PendingMarkingKeyDraftRepository) the moment it succeeds, before
/// the confirmation dialog even shows — the single most expensive,
/// hardest-to-repeat step in this whole flow. If Android kills the app in
/// the background anywhere after that (a real, normal part of the Android
/// lifecycle under memory pressure — reported as "the app switches off
/// and I lose all my progress"), [checkForResumableMarkingKeyDraft] +
/// [resumeMarkingKeyFlow] let the app pick back up right after the AI
/// step instead of making the teacher wait through it again.
///
/// Returns the saved scheme, or null if the teacher backed out at any
/// step. [onLoadingChanged] still fires around the AI call for a caller
/// that wants its own busy state too, but the real, visible progress
/// feedback now lives here — a modal dialog with live status text (was
/// previously just a small spinner glyph inside the button icon, easy to
/// miss, with no indication of what was actually happening — a real
/// reported complaint: "the upload process is covered by the same upload
/// button").
Future<MarkingScheme?> runMarkingKeyUploadFlow({
  required BuildContext context,
  required MarkingKeySourceType sourceType,
  required MarkingKeyUploadMethod method,
  required MarkingSchemeRepository schemeRepository,
  void Function(bool loading)? onLoadingChanged,
}) async {
  // Device/camera pickup and AI extraction happen FIRST, with no picker in
  // front of them — the AI extraction never actually uses subject/grade
  // (see MarkingKeyGenerationService.deriveFromText/deriveFromImages, which
  // send only the document itself), so there's no reason to make a teacher
  // pick a subject before even opening the gallery or camera. Subject/grade/
  // topic is asked afterwards, once there's a real derived key to file it
  // under — see MarkingSchemeBuilderScreen below.
  final keyGenerationService = MarkingKeyGenerationService();
  final statusNotifier = ValueNotifier<String>('Starting…');
  DerivedMarkingKey derived;

  try {
    if (method == MarkingKeyUploadMethod.uploadFromDevice) {
      final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png']);
      if (results.isEmpty || !context.mounted) return null;
      final file = results.single;
      final extension = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : '';
      final isImage = ['jpg', 'jpeg', 'png'].contains(extension);

      onLoadingChanged?.call(true);
      if (context.mounted) _showProgressDialog(context, statusNotifier, isImage ? 'Reading marking key' : 'Reading PDF marking key');
      final bytes = await file.readAsBytes();
      derived = isImage
          ? await keyGenerationService.deriveFromImageBytes(
              [bytes],
              sourceType: sourceType,
              onProgress: (s) => statusNotifier.value = s,
            )
          : await keyGenerationService.deriveFromText(
              await SubjectContentExtractionService().extractText(bytes, onProgress: (s) => statusNotifier.value = s),
              sourceType: sourceType,
              onProgress: (s) => statusNotifier.value = s,
            );
    } else {
      final pages = await Navigator.of(context).push<List<File>>(
        MaterialPageRoute(
          builder: (_) => DocumentPagesCaptureScreen(
            title: sourceType == MarkingKeySourceType.markingKey ? 'Capture Marking Key' : 'Capture Question Paper',
          ),
        ),
      );
      if (pages == null || pages.isEmpty || !context.mounted) return null;

      onLoadingChanged?.call(true);
      if (context.mounted) _showProgressDialog(context, statusNotifier, 'Reading marking key');
      derived = await keyGenerationService.deriveFromImages(
        pages,
        sourceType: sourceType,
        onProgress: (s) => statusNotifier.value = s,
      );
    }
  } catch (error) {
    onLoadingChanged?.call(false);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop(); // close the progress dialog
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not generate a marking key: $error')),
    );
    return null;
  }
  onLoadingChanged?.call(false);
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop(); // close the progress dialog
  if (!context.mounted) return null;

  // The expensive part is done — persist it to disk immediately, before
  // anything else can go wrong (app backgrounded and killed, teacher
  // distracted, etc). See this function's own doc comment.
  await PendingMarkingKeyDraftRepository().save(derived);
  if (!context.mounted) return null;

  return _finishMarkingKeyFlow(context: context, derived: derived, schemeRepository: schemeRepository);
}

/// Whether there's an AI-derived marking key sitting on disk, not yet
/// turned into a saved MarkingScheme — call this wherever a teacher might
/// re-enter AI-Assisted Marking (e.g. MarkingQueueScreen.initState) to
/// offer resuming it.
Future<PendingMarkingKeyDraft?> checkForResumableMarkingKeyDraft() => PendingMarkingKeyDraftRepository().load();

/// Resumes a previously-saved [PendingMarkingKeyDraft] — skips the device/
/// camera pickup and the AI call entirely (already done, and expensive to
/// repeat), going straight to the confirmation → details form → builder
/// tail that [runMarkingKeyUploadFlow] also uses.
Future<MarkingScheme?> resumeMarkingKeyFlow({
  required BuildContext context,
  required PendingMarkingKeyDraft draft,
  required MarkingSchemeRepository schemeRepository,
}) =>
    _finishMarkingKeyFlow(context: context, derived: draft.asDerivedMarkingKey, schemeRepository: schemeRepository);

Future<MarkingScheme?> _finishMarkingKeyFlow({
  required BuildContext context,
  required DerivedMarkingKey derived,
  required MarkingSchemeRepository schemeRepository,
}) async {
  // Explicit acknowledgement before moving on — a real reported gap:
  // teachers had no confirmation that the key was actually read before
  // the app moved to the next screen, which felt unexplained.
  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Marking key read'),
      content: Text(
        'Found ${derived.questions.length} question(s).'
        '${derived.notes.trim().isNotEmpty ? '\n\n${derived.notes}' : ''}'
        '\n\nNext, fill in a few details, then review every question before saving.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Continue')),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return null;

  // Manual entry — subject name, level, and type of exam are plain text
  // the teacher types themselves, not picked from the app's bundled
  // syllabus data. A full mock exam/past paper doesn't map to one topic,
  // so there's no topic picker in this flow at all anymore.
  final details = await Navigator.of(context).push<MarkingKeyDetails>(
    MaterialPageRoute(
      builder: (_) => MarkingKeyDetailsFormScreen(
        detectedTitle: derived.detectedTitle,
        questionCount: derived.questions.length,
      ),
    ),
  );
  if (details == null || !context.mounted) return null;

  final saved = await Navigator.of(context).push<MarkingScheme>(
    MaterialPageRoute(
      builder: (_) => MarkingSchemeBuilderScreen(
        subjectName: details.subjectName,
        gradeName: details.level,
        topicName: details.examType,
        initialQuestions: derived.questions,
        aiNotes: derived.notes,
        aiDetectedSections: derived.sections,
        repository: schemeRepository,
      ),
    ),
  );
  // Only clear the pending draft once it's actually a saved MarkingScheme
  // — backing out of the builder screen (saved == null) leaves the draft
  // in place so it's still resumable next time.
  if (saved != null) await PendingMarkingKeyDraftRepository().clear();
  return saved;
}

/// A non-dismissible modal with live-updating status text — replaces the
/// previous "tiny spinner glyph on the button, no text anywhere" feedback.
void _showProgressDialog(BuildContext context, ValueListenable<String> status, String title) {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (context, value, _) => Text(value),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
