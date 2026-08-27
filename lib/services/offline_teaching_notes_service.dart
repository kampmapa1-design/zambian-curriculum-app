import '../models/scheme_of_work.dart';
import '../utils/text_utils.dart';

/// Composes teaching notes directly from syllabus data already on-device —
/// no network, no Firebase, no API cost. This is the free substitute for
/// the AI-generated version (see TeachingNotesService) while the Firebase
/// project is still on the free Spark plan: less elaborated than an
/// AI-written essay, but zero cost and zero risk of fabricating content,
/// since every line is built directly from real, already-sourced syllabus
/// text rather than generated.
class OfflineTeachingNotesService {
  /// [subjectContentExcerpt] is real content pulled from a downloaded
  /// Teaching Module in the on-device Subject Content Database — see
  /// SubjectContentRepository.findRelevantExcerpt — woven in as an
  /// "Additional background" section so notes aren't limited to the
  /// syllabus's own thin topic/objective/competency fields when richer
  /// material is available. Entirely optional: omit it (or pass null,
  /// e.g. when nothing relevant is stored) and this behaves exactly as it
  /// always has.
  String compose({
    required SchemeOfWorkEntry entry,
    required String format,
    String? subjectContentExcerpt,
  }) {
    final title = entry.title;
    final description = (entry.subTopic?.description ?? entry.topic.description)?.trim();
    final competencies = entry.competencies.map((c) => c.description).toList();
    final activities = entry.objectives.map((o) => o.description).toList();

    return format == 'paragraph'
        ? _capWords(_paragraphs(title, description, competencies, activities, subjectContentExcerpt), _maxEssayWords)
        : _bullets(title, description, competencies, activities, subjectContentExcerpt);
  }

  /// Essay-format notes are capped at 700 words; bulletin/slide formats are
  /// already condensed, so no cap applies to them.
  static const _maxEssayWords = 700;

  static const _footer = 'These notes are composed directly from the syllabus data on this device — '
      'no internet connection or AI was used to generate them.';

  /// Applies the 700-word essay cap, dropping the footer first (it's
  /// regenerated below) so truncation never silently swallows it.
  String _capWords(String text, int maxWords) {
    final withoutFooter = text.endsWith(_footer) ? text.substring(0, text.length - _footer.length).trim() : text;
    final capped = capWords(withoutFooter, maxWords);
    if (capped == withoutFooter) return text;
    return '$capped\n\n(Trimmed to stay within the 700-word essay limit.)\n\n$_footer';
  }

  String _bullets(
    String title,
    String? description,
    List<String> competencies,
    List<String> activities,
    String? subjectContentExcerpt,
  ) {
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
    if (subjectContentExcerpt != null && subjectContentExcerpt.isNotEmpty) {
      buffer.writeln('Additional background (from your downloaded Teaching Module):');
      buffer.writeln(subjectContentExcerpt);
      buffer.writeln();
    }
    buffer.write(_footer);
    return buffer.toString().trim();
  }

  String _paragraphs(
    String title,
    String? description,
    List<String> competencies,
    List<String> activities,
    String? subjectContentExcerpt,
  ) {
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
    if (subjectContentExcerpt != null && subjectContentExcerpt.isNotEmpty) {
      buffer.writeln(subjectContentExcerpt);
      buffer.writeln();
    }
    buffer.write(_footer);
    return buffer.toString().trim();
  }
}
