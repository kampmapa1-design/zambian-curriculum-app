import 'dart:io';

import 'package:file_picker/file_picker.dart';
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
/// flow: subject/grade → term/topic → device-or-camera → Gemini →
/// MarkingSchemeBuilderScreen (pre-filled, always reviewed, never
/// auto-saved — see the Cloud Function's own comment for why a question
/// paper especially can't just be trusted directly). Shared by
/// MarkingSchemeListScreen's "New Scheme" flow and the AI-Assisted
/// Marking hub's direct "Upload Marking Key" button so both go through
/// identical behavior rather than two copies drifting apart.
///
/// Returns the saved scheme, or null if the teacher backed out at any
/// step. [onLoadingChanged] fires around the actual AI call (device/
/// camera pickers have their own loading UI) so a caller can show its
/// own busy state.
Future<MarkingScheme?> runMarkingKeyUploadFlow({
  required BuildContext context,
  required MarkingKeySourceType sourceType,
  required MarkingKeyUploadMethod method,
  required MarkingSchemeRepository schemeRepository,
  void Function(bool loading)? onLoadingChanged,
}) async {
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

  final keyGenerationService = MarkingKeyGenerationService();
  DerivedMarkingKey derived;

  try {
    if (method == MarkingKeyUploadMethod.uploadFromDevice) {
      final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png']);
      if (results.isEmpty || !context.mounted) return null;
      final file = results.single;
      final extension = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : '';
      final isImage = ['jpg', 'jpeg', 'png'].contains(extension);

      onLoadingChanged?.call(true);
      final bytes = await file.readAsBytes();
      derived = isImage
          ? await keyGenerationService.deriveFromImageBytes([bytes], sourceType: sourceType)
          : await keyGenerationService.deriveFromText(
              await SubjectContentExtractionService().extractText(bytes),
              sourceType: sourceType,
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
      derived = await keyGenerationService.deriveFromImages(pages, sourceType: sourceType);
    }
  } catch (error) {
    onLoadingChanged?.call(false);
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not generate a marking key: $error')),
    );
    return null;
  }
  onLoadingChanged?.call(false);
  if (!context.mounted) return null;

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
