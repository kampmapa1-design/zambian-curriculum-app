// Sugo Library Stage 2 — offline data-extraction tool (NOT a real test, run
// explicitly via `flutter test test/tool_generate_sugo_library.dart`; the
// filename deliberately doesn't end in `_test.dart` so a routine full-suite
// `flutter test` run never picks it up).
//
// Purpose: walk every real bundled syllabus topic, run the existing pure
// `planSugoLibraryTopic` decision logic against it, and dump the results to
// local JSON files — split into (a) notes that are already finished with NO
// AI call needed (mechanical tier + unavailable tier) and (b) "condensing
// requests" for topics that need one AI call to turn a real source excerpt
// into bulletin notes + recall questions (tier b). (b) is batched into small
// files meant to be pasted into a separate AI chat session (ChatGPT/Gemini/
// Claude.ai — any of them, since it's plain text generation, not a Claude
// Code tool-use task) for actual content generation; this script never
// authenticates to anything or calls any paid API itself.
//
// Reuses the app's own already-tested data access (TemplateRepository +
// EmbeddedLessonPlanRepository) rather than hand-parsing syllabus JSON again,
// so the real `learning_objectives`/`competencies` extraction quirks handled
// in DatabaseHelper don't need to be re-replicated here.
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

/// assets/subject_content/<dir> directory names are a snake_case version of
/// the real subject name (e.g. "Principles of Accounts" -> "principles_of_accounts").
String _slugify(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

/// Every cleaned .txt file's content for one subject's bundled Subject
/// Content Database directory, loaded once and reused across every topic in
/// that subject (avoids re-reading the same files per topic).
class _SubjectContent {
  final List<String> texts;
  const _SubjectContent(this.texts);
}

final Map<String, _SubjectContent?> _contentCache = {};

_SubjectContent? _loadSubjectContent(String subjectName, {required bool seniorSecondary}) {
  final dirName = _slugify(subjectName);
  final cacheKey = '$dirName|$seniorSecondary';
  if (_contentCache.containsKey(cacheKey)) return _contentCache[cacheKey];
  final dir = Directory('assets/subject_content/$dirName');
  if (!dir.existsSync()) {
    _contentCache[cacheKey] = null;
    return null;
  }
  final texts = <String>[];
  for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.txt'))) {
    final raw = f.readAsStringSync();
    texts.add(seniorSecondary ? cleanSourceText(raw) : raw);
  }
  final content = _SubjectContent(texts);
  _contentCache[cacheKey] = content;
  return content;
}

String? _findExcerpt(String subjectName, String topicName, String? subTopicName, {required bool seniorSecondary}) {
  final content = _loadSubjectContent(subjectName, seniorSecondary: seniorSecondary);
  if (content == null || content.texts.isEmpty) return null;
  final keywords = keywordsOf('$topicName ${subTopicName ?? ''}');
  String? best;
  var bestScore = 0;
  for (final text in content.texts) {
    final found = bestExcerptFor(text, keywords);
    if (found != null && found.score > bestScore) {
      bestScore = found.score;
      best = found.excerpt;
    }
  }
  return best;
}

void main() {
  test('generate sugo library handoff data', () async {
    await setUpTestDatabase();

    final templateRepo = TemplateRepository();
    await templateRepo.ensureAllSeeded();
    final manifest = await templateRepo.loadManifest();
    final embeddedRepo = EmbeddedLessonPlanRepository();

    final readyNotes = <Map<String, Object?>>[];
    final condensingRequests = <Map<String, Object?>>[];
    final skippedTemplates = <String>[];
    var mechanicalCount = 0;
    var unavailableCount = 0;

    for (final manifestEntry in manifest) {
      final template = await templateRepo.loadSyllabus(
        curriculumCode: manifestEntry.curriculumCode,
        subjectCode: manifestEntry.subjectCode,
        gradeLevel: manifestEntry.gradeLevel,
      );
      if (template == null) {
        skippedTemplates.add('${manifestEntry.curriculumCode}/${manifestEntry.subjectCode}/g${manifestEntry.gradeLevel}');
        continue;
      }
      final seniorSecondary = isSeniorSecondaryCurriculum(template.curriculum.code);
      final entries = allSchemeOfWorkEntries(template);

      for (final entry in entries) {
        final topicId = SugoLibraryTopicId(
          curriculumCode: template.curriculum.code,
          subjectCode: template.subject.code,
          gradeLevel: template.grade.level,
          topicName: entry.topic.name,
          subTopicName: entry.subTopic?.name,
        );

        final embeddedMatches = await embeddedRepo.find(
          curriculumCode: template.curriculum.code,
          subjectCode: template.subject.code,
          gradeLevel: template.grade.level,
          topicName: entry.topic.name,
          subtopicName: entry.subTopic?.name,
        );

        final groundingExcerpt = embeddedMatches.isNotEmpty
            ? null
            : _findExcerpt(template.subject.name, entry.topic.name, entry.subTopic?.name,
                seniorSecondary: seniorSecondary);

        final plan = planSugoLibraryTopic(
          topicId: topicId,
          subjectName: template.subject.name,
          curriculumCode: template.curriculum.code,
          embeddedMatches: embeddedMatches,
          groundingExcerpt: groundingExcerpt,
          competencies: [for (final c in entry.competencies) c.description],
          objectives: [for (final o in entry.objectives) o.description],
        );

        switch (plan) {
          case SugoLibraryReadyNote(:final note):
            if (note.sourceTier == SugoLibrarySourceTier.mechanical) {
              mechanicalCount++;
            } else {
              unavailableCount++;
            }
            readyNotes.add({
              'topicId': topicId.slug,
              'curriculumCode': topicId.curriculumCode,
              'subjectCode': topicId.subjectCode,
              'gradeLevel': topicId.gradeLevel,
              ...note.toMap(),
            });
          case SugoLibraryCondensingRequest(
              :final topicId,
              :final subjectName,
              :final curriculumLabel,
              :final groundingExcerpt,
              :final competencies,
              :final objectives,
              :final wordCap,
            ):
            condensingRequests.add({
              'topicId': topicId.slug,
              'curriculumCode': topicId.curriculumCode,
              'subjectCode': topicId.subjectCode,
              'gradeLevel': topicId.gradeLevel,
              'topicName': topicId.topicName,
              'subTopicName': topicId.subTopicName,
              'subjectName': subjectName,
              'curriculumLabel': curriculumLabel,
              'groundingExcerpt': groundingExcerpt,
              'competencies': competencies,
              'objectives': objectives,
              'wordCap': wordCap,
            });
        }
      }
    }

    const outDir = r'C:\Users\user\AppData\Local\Temp\claude\C--Users-user-Contacts\46bdade6-6bf8-4704-b4b2-de88c3b19de4\scratchpad\sugo_library_handoff';
    Directory(outDir).createSync(recursive: true);
    final batchesDir = Directory('$outDir/condensing_batches');
    if (batchesDir.existsSync()) batchesDir.deleteSync(recursive: true);
    batchesDir.createSync(recursive: true);

    File('$outDir/ready_notes.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(readyNotes));

    const batchSize = 50;
    final batchFiles = <String>[];
    for (var i = 0; i < condensingRequests.length; i += batchSize) {
      final batch = condensingRequests.sublist(i, (i + batchSize).clamp(0, condensingRequests.length));
      final fileName = 'batch_${(i ~/ batchSize + 1).toString().padLeft(3, '0')}.json';
      File('$outDir/condensing_batches/$fileName').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(batch));
      batchFiles.add(fileName);
    }

    final summary = {
      'totalManifestEntries': manifest.length,
      'skippedTemplates': skippedTemplates,
      'totalTopics': readyNotes.length + condensingRequests.length,
      'mechanicalTier': mechanicalCount,
      'unavailableTier': unavailableCount,
      'aiCondensedTier': condensingRequests.length,
      'condensingBatchCount': batchFiles.length,
      'condensingBatchSize': batchSize,
      'condensingBatchFiles': batchFiles,
    };
    File('$outDir/summary.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));

    // ignore: avoid_print
    print('SUGO_LIBRARY_GENERATION_SUMMARY: ${jsonEncode(summary)}');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
