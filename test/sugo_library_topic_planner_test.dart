import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/embedded_lesson_plan.dart';
import 'package:zambian_curriculum_app/models/sugo_library_note.dart';
import 'package:zambian_curriculum_app/services/sugo_library_topic_planner.dart';

const _topicId = SugoLibraryTopicId(
  curriculumCode: 'OBC_2013',
  subjectCode: 'BIO',
  gradeLevel: 10,
  topicName: 'Cell Structure',
  subTopicName: 'Plant Cells',
);

/// Sugo Library Stage 2 — guards the three-tier decision itself, entirely
/// offline: an exact embedded-lesson-plan match always wins (mechanical, no
/// AI, no questions); real source text with no embedded match needs
/// condensing (AI, with questions); nothing at all is honestly
/// "unavailable" rather than padded from bare syllabus data alone.
void main() {
  group('tier (a): mechanical', () {
    test('an embedded lesson plan match produces a ready note with no AI call', () {
      final plan = const EmbeddedLessonPlan(
        topicName: 'Cell Structure',
        subtopicName: 'Plant Cells',
        majorLearningPoint: 'Plant cells have a cell wall.',
        objectives: ['Identify the parts of a plant cell.'],
      );
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'OBC_2013',
        embeddedMatches: [plan],
      );
      expect(result, isA<SugoLibraryReadyNote>());
      final note = (result as SugoLibraryReadyNote).note;
      expect(note.sourceTier, SugoLibrarySourceTier.mechanical);
      expect(note.questions, isEmpty, reason: 'only tier (b) gets questions');
      expect(note.notes, contains('Plant cells have a cell wall.'));
    });

    test('duplicate lines across several matching lesson plans are not repeated', () {
      final a = const EmbeddedLessonPlan(topicName: 'X', majorLearningPoint: 'Same point.');
      final b = const EmbeddedLessonPlan(topicName: 'X', majorLearningPoint: 'Same point.');
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'CBC_2023',
        embeddedMatches: [a, b],
      ) as SugoLibraryReadyNote;
      expect(result.note.notes.where((l) => l == 'Same point.'), hasLength(1));
    });

    test('Grade 10-12 (OBC) content has Form-level mentions silently stripped, never a "?"', () {
      final plan = const EmbeddedLessonPlan(
        topicName: 'X',
        majorLearningPoint: 'This was taught in Form 2 as well.',
        objectives: ['A clean objective with no junior-form mention.'],
      );
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'OBC_2013',
        embeddedMatches: [plan],
      ) as SugoLibraryReadyNote;
      expect(result.note.notes.any((l) => l.contains('Form')), isFalse);
      expect(result.note.notes.any((l) => l.contains('?')), isFalse);
    });
  });

  group('tier (b): AI condensing', () {
    test('real source text with no embedded match asks for condensing, not a ready note', () {
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'CBC_2023',
        embeddedMatches: const [],
        groundingExcerpt: 'A real excerpt about plant cell structure and function.',
        competencies: ['Describe cell structure.'],
        objectives: ['Explain the function of the cell wall.'],
      );
      expect(result, isA<SugoLibraryCondensingRequest>());
      final req = result as SugoLibraryCondensingRequest;
      expect(req.curriculumLabel, 'CBC');
      expect(req.competencies, ['Describe cell structure.']);
    });

    test('word cap scales down for a short real excerpt, never padded to 600', () {
      final short = List.filled(20, 'word').join(' ');
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'CBC_2023',
        embeddedMatches: const [],
        groundingExcerpt: short,
      ) as SugoLibraryCondensingRequest;
      expect(result.wordCap, lessThan(600));
    });

    test('a long real excerpt gets the full 600-word cap', () {
      final long = List.filled(500, 'word').join(' ');
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'CBC_2023',
        embeddedMatches: const [],
        groundingExcerpt: long,
      ) as SugoLibraryCondensingRequest;
      expect(result.wordCap, 600);
    });

    test('an OBC (senior-secondary) topic is labelled OBC in the condensing request', () {
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'OBC_2013',
        embeddedMatches: const [],
        groundingExcerpt: 'Real source text here.',
      ) as SugoLibraryCondensingRequest;
      expect(result.curriculumLabel, 'OBC');
    });
  });

  group('tier (c): unavailable', () {
    test('no embedded match and no grounding excerpt is honestly "unavailable", not padded', () {
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'CBC_2023',
        embeddedMatches: const [],
        competencies: ['Some bare competency with no real excerpt behind it.'],
      );
      expect(result, isA<SugoLibraryReadyNote>());
      final note = (result as SugoLibraryReadyNote).note;
      expect(note.sourceTier, SugoLibrarySourceTier.unavailable);
      expect(note.notes, isEmpty);
    });

    test('a blank/whitespace-only excerpt is treated the same as no excerpt at all', () {
      final result = planSugoLibraryTopic(
        topicId: _topicId,
        subjectName: 'Biology',
        curriculumCode: 'CBC_2023',
        embeddedMatches: const [],
        groundingExcerpt: '   ',
      );
      final note = (result as SugoLibraryReadyNote).note;
      expect(note.sourceTier, SugoLibrarySourceTier.unavailable);
    });
  });
}
