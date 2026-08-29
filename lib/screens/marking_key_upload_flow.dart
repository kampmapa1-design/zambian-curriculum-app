import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/marking_scheme.dart';
import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import '../services/marking_key_generation_service.dart';
import '../services/marking_scheme_repository.dart';
import '../services/subject_content_extraction_service.dart';
import 'document_pages_capture_screen.dart';
import 'marking_scheme_builder_screen.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'term_topic_picker_screen.dart';

enum MarkingKeyUploadMethod { uploadFromDevice, camera }

/// Stage B — the full "AI, read this marking key/question paper for me"
/// flow: device-or-camera → Gemini → confirmation → subject/grade → term/
/// topic → MarkingSchemeBuilderScreen (pre-filled, always reviewed, never
/// auto-saved — see the Cloud Function's own comment for why a question
/// paper especially can't just be trusted directly). Shared by
/// MarkingSchemeListScreen's "New Scheme" flow and the AI-Assisted
/// Marking hub's direct "Upload Marking Key" button so both go through
/// identical behavior rather than two copies drifting apart.
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

  // Explicit acknowledgement before jumping into subject/grade/topic
  // pickers — a real reported gap: teachers had no confirmation that the
  // key was actually read before the app moved on, making the following
  // subject picker feel unexplained ("for reasons not clear to the user").
  final proceed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Marking key read'),
      content: Text(
        'Found ${derived.questions.length} question(s).'
        '${derived.notes.trim().isNotEmpty ? '\n\n${derived.notes}' : ''}'
        '\n\nNext, choose which subject/grade/topic this belongs to, then review every question before saving.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Continue')),
      ],
    ),
  );
  if (proceed != true || !context.mounted) return null;

  // Now that there's a real derived key in hand, ask which subject/grade/
  // topic it belongs to — needed to file the saved MarkingScheme, but no
  // longer blocking the camera/gallery from opening immediately above.
  final template = await Navigator.of(context).push<SyllabusTemplate>(
    MaterialPageRoute(
      builder: (_) => const SubjectGradeTopicPickerScreen(title: 'Subject & Grade', pickTopic: false),
    ),
  );
  if (template == null || !context.mounted) return null;

  final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
    MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template)),
  );
  if (entry == null || !context.mounted) return null;

  return Navigator.of(context).push<MarkingScheme>(
    MaterialPageRoute(
      builder: (_) => MarkingSchemeBuilderScreen(
        subjectName: template.subject.name,
        gradeName: template.grade.name,
        topicName: entry.topic.name,
        subTopicName: entry.subTopic?.name,
        initialQuestions: derived.questions,
        aiNotes: derived.notes,
        repository: schemeRepository,
      ),
    ),
  );
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
