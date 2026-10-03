// Sugo Library — offline source-extraction tool (NOT a real test, run
// explicitly via `flutter test test/tool_generate_sugo_library.dart`; the
// filename deliberately doesn't end in `_test.dart` so a routine full-suite
// `flutter test` run never picks it up).
//
// For every real bundled syllabus topic it gathers the LEARNER-appropriate
// source material the notes will be written from:
//   - a Subject Content Database excerpt (bundled assets read straight off
//     disk, never a device's own uploads),
//   - the embedded lesson plans' learning points (majorLearningPoint +
//     objectives ONLY — the teacher-role/progression rows are teacher
//     instructions and are deliberately never used),
//   - the syllabus's own competencies/objectives.
// Topics with no excerpt AND no lesson-plan points are listed separately as
// "deferred" (nothing real to ground notes in). Output goes to the Sugo
// Library factory folder; nothing here touches the network or any account.
//
// Reuses the app's own tested data access (TemplateRepository +
// EmbeddedLessonPlanRepository) so syllabus parsing quirks aren't re-done.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/scheme_of_work.dart';
import 'package:zambian_curriculum_app/models/sugo_library_note.dart';
import 'package:zambian_curriculum_app/services/embedded_lesson_plan_repository.dart';
import 'package:zambian_curriculum_app/services/senior_secondary_content_filter.dart';
import 'package:zambian_curriculum_app/services/sugo_library_topic_planner.dart';
import 'package:zambian_curriculum_app/services/template_repository.dart';
import 'package:zambian_curriculum_app/services/text_excerpt_matching.dart';

import 'support/sqlite_test_setup.dart';

const _outDir = r'C:\Users\user\Documents\SugoLibrary_Factory\_data';

String _slugify(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

final Map<String, List<String>?> _contentCache = {};

List<String>? _loadSubjectContent(String subjectName, {required bool seniorSecondary}) {
  final dirName = _slugify(subjectName);
  final cacheKey = '$dirName|$seniorSecondary';
  if (_contentCache.containsKey(cacheKey)) return _contentCache[cacheKey];
  final dir = Directory('assets/subject_content/$dirName');
  if (!dir.existsSync()) return _contentCache[cacheKey] = null;
  final texts = <String>[];
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.txt'))) {
    final raw = f.readAsStringSync();
    texts.add(seniorSecondary ? cleanSourceText(raw) : raw);
  }
  return _contentCache[cacheKey] = texts;
}

String? _findExcerpt(String subjectName, String topicName, String? subTopicName, {required bool seniorSecondary}) {
  final texts = _loadSubjectContent(subjectName, seniorSecondary: seniorSecondary);
  if (texts == null || texts.isEmpty) return null;
  final keywords = keywordsOf('$topicName ${subTopicName ?? ''}');
  String? best;
  var bestScore = 0;
  for (final text in texts) {
    final found = bestExcerptFor(text, keywords);
    if (found != null && found.score > bestScore) {
      bestScore = found.score;
      best = found.excerpt;
    }
  }
  return best;
}

void main() {
  test('generate sugo library learner source data', () async {
    await setUpTestDatabase();

    final templateRepo = TemplateRepository();
    await templateRepo.ensureAllSeeded();
    final manifest = await templateRepo.loadManifest();
    final embeddedRepo = EmbeddedLessonPlanRepository();

    final withSource = <Map<String, Object?>>[];
    final deferred = <Map<String, Object?>>[];
    var viaExcerpt = 0, viaLessonPlanOnly = 0;

    for (final manifestEntry in manifest) {
      final template = await templateRepo.loadSyllabus(
        curriculumCode: manifestEntry.curriculumCode,
        subjectCode: manifestEntry.subjectCode,
        gradeLevel: manifestEntry.gradeLevel,
      );
      if (template == null) continue;
      final seniorSecondary = isSeniorSecondaryCurriculum(template.curriculum.code);

      for (final entry in allSchemeOfWorkEntries(template)) {
        final topicId = SugoLibraryTopicId(
          curriculumCode: template.curriculum.code,
          subjectCode: template.subject.code,
          gradeLevel: template.grade.level,
          topicName: entry.topic.name,
          subTopicName: entry.subTopic?.name,
        );

        final plans = await embeddedRepo.find(
          curriculumCode: template.curriculum.code,
          subjectCode: template.subject.code,
          gradeLevel: template.grade.level,
          topicName: entry.topic.name,
          subtopicName: entry.subTopic?.name,
        );
        final lessonPlanPoints = <String>[];
        for (final plan in plans) {
          final candidates = [plan.majorLearningPoint, ...plan.objectives];
          for (final c in candidates) {
            final t = c?.trim();
            if (t == null || t.isEmpty) continue;
            final cleaned = seniorSecondary ? cleanGeneratedText(t) : t;
            if (cleaned.trim().isNotEmpty && !lessonPlanPoints.contains(cleaned)) lessonPlanPoints.add(cleaned);
          }
        }

        final excerpt = _findExcerpt(template.subject.name, entry.topic.name, entry.subTopic?.name,
            seniorSecondary: seniorSecondary);
        final competencies = [for (final c in entry.competencies) c.description];
        final objectives = [for (final o in entry.objectives) o.description];

        final row = <String, Object?>{
          'topicId': topicId.slug,
          'curriculumCode': topicId.curriculumCode,
          'subjectCode': topicId.subjectCode,
          'gradeLevel': topicId.gradeLevel,
          'gradeName': template.grade.name,
          'subjectName': template.subject.name,
          'curriculumLabel': seniorSecondary ? 'OBC' : 'CBC',
          'topicName': topicId.topicName,
          'subTopicName': topicId.subTopicName,
          'groundingExcerpt': excerpt,
          'lessonPlanPoints': lessonPlanPoints,
          'competencies': competencies,
          'objectives': objectives,
          'wordCap': scaledSugoLibraryWordCap('${excerpt ?? ''} ${lessonPlanPoints.join(' ')}'),
        };
        if (excerpt != null || lessonPlanPoints.isNotEmpty) {
          if (excerpt != null) {
            viaExcerpt++;
          } else {
            viaLessonPlanOnly++;
          }
          withSource.add(row);
        } else {
          deferred.add(row);
        }
      }
    }

    Directory(_outDir).createSync(recursive: true);
    File('$_outDir/learner_source.json').writeAsStringSync(jsonEncode({'withSource': withSource, 'deferred': deferred}));
    // ignore: avoid_print
    print('SUGO_LEARNER_SOURCE_SUMMARY: ${jsonEncode({
      'withSource': withSource.length,
      'viaExcerpt': viaExcerpt,
      'viaLessonPlanOnly': viaLessonPlanOnly,
      'deferredNoSource': deferred.length,
    })}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
