// Grade 10-12 (OBC) documents must never mention Form 1-5 or carry question
// marks (2026-09-27). Checked against the REAL bundled subject-content files
// (which include CBC Form 1 teaching modules and ECZ past papers), not just
// hand-written strings.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/lesson_plan.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/syllabus_models.dart';
import 'package:zambian_curriculum_app/services/lesson_progression_generator.dart';
import 'package:zambian_curriculum_app/services/senior_secondary_content_filter.dart';
import 'package:zambian_curriculum_app/services/text_excerpt_matching.dart';

List<File> _bundledContent() => Directory('assets/subject_content')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.txt'))
    .toList();

final _formLevel = RegExp(r'\bforms?\s*(?:[1-5]|one|two|three|four|five)\b|\bF[1-5]\b', caseSensitive: false);

void main() {
  group('cleanSourceText on the real bundled material', () {
    test('the raw material really does contain what must be filtered (so the filter is doing real work)', () {
      final raw = File('assets/subject_content/biology/form1_biology_teaching_module_form_1_term_2.txt').readAsStringSync();
      expect(_formLevel.hasMatch(raw), isTrue);
      final essays = File('assets/subject_content/biology/ecz_biology_p2_essay_2009_2019.txt').readAsStringSync();
      expect(essays.contains('?'), isTrue);
    });

    test('EVERY bundled file: cleaned text has no Form level, no question mark, no paper scaffolding', () {
      final files = _bundledContent();
      expect(files.length, greaterThan(20));
      for (final f in files) {
        final cleaned = cleanSourceText(f.readAsStringSync());
        expect(_formLevel.hasMatch(cleaned), isFalse, reason: f.path);
        expect(cleaned.contains('?'), isFalse, reason: f.path);
        expect(cleaned.contains('�'), isFalse, reason: f.path);
        expect(RegExp(r'\bquestion\s+\d+|\bmodel answer\b|teaching module', caseSensitive: false).hasMatch(cleaned),
            isFalse, reason: f.path);
      }
    });

    test('real subject knowledge survives: the ECZ model answers still yield usable statements', () {
      final cleaned = cleanSourceText(File('assets/subject_content/biology/ecz_biology_p2_essay_2009_2019.txt').readAsStringSync());
      expect(cleaned.length, greaterThan(2000));
      expect(cleaned, contains('photosynthesis'));
    });
  });

  group('cleanGeneratedText', () {
    test('drops sentences that name a Form level but keeps the rest of the line', () {
      expect(cleanGeneratedText('Learners revise work from Form 1. They then extend it to new examples.'),
          'They then extend it to new examples.');
    });

    test('a line that is only a Form mention keeps its text, minus the mention', () {
      expect(cleanGeneratedText('Recap Form 2 ideas'), 'Recap ideas');
    });

    test('strips placeholder question marks but leaves a real question alone', () {
      expect(cleanGeneratedText('Explain the process ??'), 'Explain the process');
      expect(cleanGeneratedText('Ask learners: what is diffusion?'), 'Ask learners: what is diffusion?');
      expect(cleanGeneratedText('Osmosis (?) is the movement of water'), 'Osmosis is the movement of water');
    });

    test('keeps line structure (bullets survive)', () {
      expect(cleanGeneratedText('•  First point\n•  Second point about Form 3 work.\n•  Third point'),
          '•  First point\n•  Second point about work.\n•  Third point');
    });
  });

  group('a real Grade 10 lesson built from the cleaned material', () {
    test('no document field ever carries a Form level or a question mark', () {
      // The same excerpt the app would find for this topic — but only from the cleaned real material.
      final keywords = keywordsOf('10.1.1 Characteristics of Living Organisms');
      String? best;
      var bestScore = 0;
      for (final f in _bundledContent().where((f) => f.path.contains('biology'))) {
        final found = bestExcerptFor(cleanSourceText(f.readAsStringSync()), keywords);
        if (found != null && found.score > bestScore) {
          bestScore = found.score;
          best = found.excerpt;
        }
      }
      expect(best, isNotNull, reason: 'the bundled biology material should match this topic');

      const competencies = [
        Competency(id: 1, sequenceNumber: 1, description: 'Identify the characteristics of living organisms'),
        Competency(id: 2, sequenceNumber: 2, description: 'Distinguish between living organisms and non-living things'),
      ];
      const subTopic = SubTopic(
          id: 1, sequenceNumber: 1, name: '10.1.1 Characteristics of Living Organisms', objectives: [], competencies: competencies);
      const topic = Topic(
          id: 1, sequenceNumber: 1, name: '10.1 Living Organisms', subTopics: [subTopic], objectives: [], competencies: []);
      const entry = SchemeOfWorkEntry(weekNumber: 1, topic: topic, subTopic: subTopic, objectives: [], competencies: competencies);

      for (final mode in LessonProgressionContentMode.values) {
        final rows = generateDefaultProgression(defaultObcNaturalSciencesMathematicsLessonPlanTemplate.progressionStages, entry,
            subjectContentExcerpt: best, contentMode: mode);
        final text = [for (final r in rows) ...[r.content, r.teacherRole, r.learnersRole, r.assessmentCriteria]].join('\n');
        expect(_formLevel.hasMatch(text), isFalse, reason: '$mode: $text');
        expect(text.contains('?'), isFalse, reason: '$mode: $text');
      }
    });
  });
}
