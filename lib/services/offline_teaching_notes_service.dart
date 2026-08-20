import '../models/scheme_of_work.dart';

/// Composes teaching notes directly from syllabus data already on-device —
/// no network, no Firebase, no API cost. This is the free substitute for
/// the AI-generated version (see TeachingNotesService) while the Firebase
/// project is still on the free Spark plan: less elaborated than an
/// AI-written essay, but zero cost and zero risk of fabricating content,
/// since every line is built directly from real, already-sourced syllabus
/// text rather than generated.
class OfflineTeachingNotesService {
  String compose({required SchemeOfWorkEntry entry, required String format}) {
    final title = entry.title;
    final description = (entry.subTopic?.description ?? entry.topic.description)?.trim();
    final competencies = entry.competencies.map((c) => c.description).toList();
    final activities = entry.objectives.map((o) => o.description).toList();

    return format == 'paragraph'
        ? _paragraphs(title, description, competencies, activities)
        : _bullets(title, description, competencies, activities);
  }

  static const _footer = 'These notes are composed directly from the syllabus data on this device — '
      'no internet connection or AI was used to generate them.';

  String _bullets(String title, String? description, List<String> competencies, List<String> activities) {
    final buffer = StringBuffer()..writeln(title)..writeln();
    if (description != null && description.isNotEmpty) {
      buffer.writeln(description);
      buffer.writeln();
    }
    if (competencies.isNotEmpty) {
      buffer.writeln('What learners should be able to do:');
      for (final c in competencies) {
        buffer.writeln('•  $c');
      }
      buffer.writeln();
    }
    if (activities.isNotEmpty) {
      buffer.writeln('Suggested learning activities:');
      for (final a in activities) {
        buffer.writeln('•  $a');
      }
      buffer.writeln();
    }
    buffer.write(_footer);
    return buffer.toString().trim();
  }

  String _paragraphs(String title, String? description, List<String> competencies, List<String> activities) {
    final buffer = StringBuffer()..writeln('This lesson covers $title.');
    if (description != null && description.isNotEmpty) {
      buffer.writeln(description);
    }
    buffer.writeln();
    if (competencies.isNotEmpty) {
      buffer.writeln('By the end of the lesson, learners should be able to: ${competencies.join('; ')}.');
      buffer.writeln();
    }
    if (activities.isNotEmpty) {
      buffer.writeln('To get there, plan learning activities such as: ${activities.join('; ')}.');
      buffer.writeln();
    }
    buffer.write(_footer);
    return buffer.toString().trim();
  }
}
