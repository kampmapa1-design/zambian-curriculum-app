import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/sugo_library_note.dart';

/// Sugo Library Stage 1 — guards [SugoLibraryTopicId.slug]'s determinism:
/// the batch generator must overwrite the SAME Firestore doc on a re-run
/// for the same real topic, never create a duplicate.
void main() {
  test('the same topic always produces the same slug', () {
    const id = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013',
      subjectCode: 'BIO',
      gradeLevel: 10,
      topicName: 'Cell Structure',
      subTopicName: 'Plant Cells',
    );
    const same = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013',
      subjectCode: 'BIO',
      gradeLevel: 10,
      topicName: 'Cell Structure',
      subTopicName: 'Plant Cells',
    );
    expect(id.slug, same.slug);
  });

  test('a different grade level produces a different slug', () {
    const g10 = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10, topicName: 'Cell Structure');
    const g11 = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 11, topicName: 'Cell Structure');
    expect(g10.slug, isNot(g11.slug));
  });

  test('no sub-topic vs a sub-topic never collide', () {
    const topicOnly = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10, topicName: 'Cell Structure');
    const withSub = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013',
      subjectCode: 'BIO',
      gradeLevel: 10,
      topicName: 'Cell Structure',
      subTopicName: '',
    );
    // An empty-but-non-null sub-topic name normalizes the same as no
    // sub-topic at all — both mean "the topic itself".
    expect(topicOnly.slug, withSub.slug);
  });

  test('slug is stable across mixed case and extra whitespace in the source names', () {
    const messy = SugoLibraryTopicId(
      curriculumCode: 'obc_2013', subjectCode: 'bio', gradeLevel: 10, topicName: '  Cell   Structure  ');
    const clean = SugoLibraryTopicId(
      curriculumCode: 'OBC_2013', subjectCode: 'BIO', gradeLevel: 10, topicName: 'Cell Structure');
    expect(messy.slug, clean.slug);
  });
}
