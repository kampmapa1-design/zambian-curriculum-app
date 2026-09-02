import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/syllabus_models.dart';
import 'subject_grade_topic_picker_screen.dart';
import 'term_topic_picker_screen.dart';

/// The shared "Grade → Term → Week → Topic" drill-down (Method 1 of the
/// three topic-selection strategies discussed 2026-09-02, chosen as the
/// foundation) — Subject/Grade picked via [SubjectGradeTopicPickerScreen],
/// then Term/real-Week/Topic via `TermTopicPickerScreen`, which correctly
/// groups by each topic's REAL sourced teaching week rather than listing
/// topics flatly. Returns null if the teacher backs out at either step.
///
/// One reusable entry point instead of every "pick a specific topic"
/// feature wiring the two screens together itself — "Generate Lesson
/// Plan" already did exactly this chain; "Generate Teaching Notes &
/// Slides" used to call a different, buggier path (see
/// subject_grade_topic_picker_screen.dart's doc comment) — both now go
/// through here.
Future<SchemeOfWorkEntry?> pickTopicViaTermWeek(BuildContext context, {required String title}) async {
  final template = await Navigator.of(context).push<SyllabusTemplate>(
    MaterialPageRoute(builder: (_) => SubjectGradeTopicPickerScreen(title: title)),
  );
  if (template == null || !context.mounted) return null;

  return Navigator.of(context).push<SchemeOfWorkEntry>(
    MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template)),
  );
}
