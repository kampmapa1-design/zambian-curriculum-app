import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/lesson_references.dart';

/// References-blank bug (owner request, 2026-09-28): a topic with no
/// curated entry.references left the whole field blank — this guards the
/// fix's real guarantee, that the field is never empty and never a
/// fabricated specific citation.
void main() {
  group('guaranteedSubjectReferences', () {
    test('names the real subject and curriculum, never a fabricated specific title', () {
      final refs = guaranteedSubjectReferences(subjectName: 'Biology', isObc: true);
      expect(refs, ["Teachers' Guide for Biology", 'Syllabus for Biology (OBC Curriculum)']);
    });

    test('CBC vs OBC curriculum label switches correctly', () {
      final refs = guaranteedSubjectReferences(subjectName: 'Mathematics', isObc: false);
      expect(refs.last, contains('CBC Curriculum'));
    });

    test('falls back to a safe generic label rather than an empty subject name', () {
      final refs = guaranteedSubjectReferences(subjectName: '  ', isObc: true);
      expect(refs.first, "Teachers' Guide for the Subject");
    });
  });

  group('buildLessonPlanReferencesText', () {
    test('no curated content: exactly the 2 guaranteed generic references', () {
      final text = buildLessonPlanReferencesText(curated: null, subjectName: 'History', isObc: true);
      expect(text.split('\n'), hasLength(2));
      expect(text, contains("Teachers' Guide for History"));
      expect(text, contains('Syllabus for History'));
    });

    test('real curated content is kept first, generics appended after (3 total)', () {
      final text = buildLessonPlanReferencesText(
        curated: 'Ministry of Education Grade 11 Biology Module, Unit 3',
        subjectName: 'Biology',
        isObc: true,
      );
      final lines = text.split('\n');
      expect(lines, hasLength(3));
      expect(lines.first, 'Ministry of Education Grade 11 Biology Module, Unit 3');
    });

    test('an empty/whitespace-only curated string is treated as no curated content', () {
      final text = buildLessonPlanReferencesText(curated: '   ', subjectName: 'Geography', isObc: false);
      expect(text.split('\n'), hasLength(2));
    });

    test('never blank, even with an empty subject name', () {
      final text = buildLessonPlanReferencesText(curated: null, subjectName: '', isObc: false);
      expect(text.trim(), isNotEmpty);
    });
  });
}
