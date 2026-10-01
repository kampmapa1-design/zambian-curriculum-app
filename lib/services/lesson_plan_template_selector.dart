import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/lesson_plan.dart';

/// Category tags carried by `assets/syllabi/manifest.json` (`subject_category`
/// on a subject's entries) — data, not code: classifying a new subject is a
/// manifest edit, exactly like adding the subject itself.
const kSubjectCategoryNaturalSciencesMathematics = 'natural_sciences_mathematics';
const kSubjectCategorySocialSciences = 'social_sciences';

/// Chooses the lesson plan template for a subject, with no manual choice by
/// the teacher (2026-09-26, per explicit request).
///
/// - **CBC (2023)**: always [defaultCbcLessonPlanTemplate] — nothing about
///   the OBC template work touches it, and the category is never consulted.
/// - **OBC (2013)**: by the subject's category — Natural Sciences &
///   Mathematics → the 5-column template, Social Sciences → the 4-column
///   variant. A subject with NO category (e.g. English, Commerce — see the
///   manifest) keeps the pre-existing [defaultCdcLessonPlanTemplate]
///   unchanged rather than being silently forced into either.
///
/// Pure (no I/O) so the rule itself is directly testable; see
/// [lessonPlanTemplateForSubject] for the manifest-backed entry point.
LessonPlanTemplate selectLessonPlanTemplate({required String curriculumCode, String? subjectCategory}) {
  if (curriculumCode == 'CBC_2023') return defaultCbcLessonPlanTemplate;
  return switch (subjectCategory) {
    kSubjectCategoryNaturalSciencesMathematics => defaultObcNaturalSciencesMathematicsLessonPlanTemplate,
    kSubjectCategorySocialSciences => defaultObcSocialSciencesLessonPlanTemplate,
    _ => defaultCdcLessonPlanTemplate,
  };
}

Map<String, String>? _categoryCache;

/// `"<curriculum_code>|<subject_code>"` -> category, read once from the
/// bundled manifest.
Future<Map<String, String>> _loadCategories(AssetBundle bundle) async {
  final cached = _categoryCache;
  if (cached != null && identical(bundle, rootBundle)) return cached;
  final result = <String, String>{};
  try {
    final manifest = jsonDecode(await bundle.loadString('assets/syllabi/manifest.json')) as Map<String, dynamic>;
    for (final entry in (manifest['templates'] as List).cast<Map<String, dynamic>>()) {
      final category = entry['subject_category'];
      if (category is String && category.isNotEmpty) {
        result['${entry['curriculum_code']}|${entry['subject_code']}'] = category;
      }
    }
  } catch (_) {
    // No/unreadable manifest: every subject falls back to the default template.
  }
  if (identical(bundle, rootBundle)) _categoryCache = result;
  return result;
}

/// The category of [subjectCode] under [curriculumCode] per the manifest, or
/// null when it has none.
Future<String?> subjectCategoryFor(String curriculumCode, String subjectCode, {AssetBundle? bundle}) async {
  final categories = await _loadCategories(bundle ?? rootBundle);
  return categories['$curriculumCode|$subjectCode'];
}

/// [selectLessonPlanTemplate] for a real subject, reading its category from
/// the bundled manifest. CBC never touches the manifest.
Future<LessonPlanTemplate> lessonPlanTemplateForSubject({
  required String curriculumCode,
  required String subjectCode,
  AssetBundle? bundle,
}) async {
  if (curriculumCode == 'CBC_2023') return defaultCbcLessonPlanTemplate;
  return selectLessonPlanTemplate(
    curriculumCode: curriculumCode,
    subjectCategory: await subjectCategoryFor(curriculumCode, subjectCode, bundle: bundle),
  );
}
