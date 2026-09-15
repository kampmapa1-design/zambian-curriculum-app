// Minimal, hand-built curriculum/subject/grade/topic/sub-topic tree, run
// through the real DatabaseHelper.importTemplate ingestion path (same shape
// as assets/syllabi/*.json) — the FK graph ClassProgressRepository and
// LessonHistoryRepository tests need already sitting in the test database,
// since both repositories look their subject/grade/topic rows up by code
// rather than accepting raw ids.
import 'package:zambian_curriculum_app/services/database_helper.dart';

class SeededSyllabus {
  const SeededSyllabus({
    required this.curriculumCode,
    required this.subjectCode,
    required this.gradeLevel,
    required this.topicAId,
    required this.topicASub1Id,
    required this.topicASub2Id,
    required this.topicBId,
  });

  final String curriculumCode;
  final String subjectCode;
  final int gradeLevel;
  final int topicAId;
  final int topicASub1Id;
  final int topicASub2Id;
  final int topicBId;
}

/// Imports one small template (2 topics, the first with 2 sub-topics) and
/// returns the real ids assigned, so tests can reference genuine FK targets.
Future<SeededSyllabus> seedMinimalSyllabus(
  DatabaseHelper db, {
  String curriculumCode = 'TEST_CURRICULUM',
  String subjectCode = 'TEST_SUBJ',
  int gradeLevel = 10,
}) async {
  await db.importTemplate({
    'curriculum': {'code': curriculumCode, 'name': 'Test Curriculum', 'description': null},
    'subject': {'code': subjectCode, 'name': 'Test Subject', 'description': null},
    'grade': {'code': 'G$gradeLevel', 'name': 'Grade $gradeLevel', 'level': gradeLevel, 'phase': null},
    'terms': [
      {
        'code': 'T1',
        'name': 'Term 1',
        'sequence_number': 1,
        'topics': [
          {
            'name': 'Topic A',
            'sequence_number': 1,
            'description': null,
            'week_number': 1,
            'references': null,
            'learning_objectives': <Map<String, dynamic>>[],
            'competencies': <Map<String, dynamic>>[],
            'sub_topics': [
              {
                'name': 'A.1',
                'sequence_number': 1,
                'description': null,
                'week_number': 1,
                'references': null,
                'learning_objectives': <Map<String, dynamic>>[],
                'competencies': [
                  {'sequence_number': 1, 'description': 'Competency A.1', 'category': null},
                ],
              },
              {
                'name': 'A.2',
                'sequence_number': 2,
                'description': null,
                'week_number': 2,
                'references': null,
                'learning_objectives': <Map<String, dynamic>>[],
                'competencies': [
                  {'sequence_number': 1, 'description': 'Competency A.2', 'category': null},
                ],
              },
            ],
          },
          {
            'name': 'Topic B',
            'sequence_number': 2,
            'description': null,
            'week_number': 3,
            'references': null,
            'learning_objectives': <Map<String, dynamic>>[],
            'competencies': [
              {'sequence_number': 1, 'description': 'Competency B', 'category': null},
            ],
            'sub_topics': <Map<String, dynamic>>[],
          },
        ],
      },
    ],
  });

  final template = await db.getSyllabus(
    curriculumCode: curriculumCode,
    subjectCode: subjectCode,
    gradeLevel: gradeLevel,
  );
  final topicA = template!.terms.single.topics.firstWhere((t) => t.name == 'Topic A');
  final topicB = template.terms.single.topics.firstWhere((t) => t.name == 'Topic B');

  return SeededSyllabus(
    curriculumCode: curriculumCode,
    subjectCode: subjectCode,
    gradeLevel: gradeLevel,
    topicAId: topicA.id,
    topicASub1Id: topicA.subTopics[0].id,
    topicASub2Id: topicA.subTopics[1].id,
    topicBId: topicB.id,
  );
}
