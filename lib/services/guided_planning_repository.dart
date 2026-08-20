import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/activity_bank.dart';
import '../models/cdc_constraint_rules.dart';

/// Loads Stage 5's bundled activity banks (assets/activity_banks/*.json)
/// and CDC constraint rules (assets/rules/*.json) — both plain bundled
/// assets, no database needed given how few of these exist so far.
class GuidedPlanningRepository {
  Future<List<Map<String, dynamic>>> _loadManifest() async {
    final raw = await rootBundle.loadString('assets/activity_banks/manifest.json');
    return (jsonDecode(raw)['banks'] as List).cast<Map<String, dynamic>>();
  }

  /// The activity bank for one sub-topic, or null if none has been sourced
  /// yet — guided planning only offers itself where real content exists,
  /// rather than fabricating activities for topics without one.
  Future<ActivityBank?> loadBankFor({
    required String curriculumCode,
    required String subjectCode,
    required String subTopicName,
  }) async {
    final manifest = await _loadManifest();
    Map<String, dynamic>? entry;
    for (final e in manifest) {
      if (e['curriculum_code'] == curriculumCode &&
          e['subject_code'] == subjectCode &&
          e['sub_topic_name'] == subTopicName) {
        entry = e;
        break;
      }
    }
    if (entry == null) return null;
    final raw = await rootBundle.loadString('assets/activity_banks/${entry['file']}');
    return ActivityBank.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// The constraint rules for one curriculum. Falls back to the worked
  /// example (assets/rules/cdc_constraints.example.json) if no
  /// curriculum-specific rules file has been authored yet, so the engine
  /// always has something real to enforce rather than nothing at all.
  Future<CdcConstraintRuleSet?> loadRulesFor(String curriculumCode) async {
    final candidatePaths = [
      'assets/rules/${curriculumCode.toLowerCase()}_constraints.json',
      'assets/rules/cdc_constraints.example.json',
    ];
    for (final path in candidatePaths) {
      try {
        final raw = await rootBundle.loadString(path);
        return CdcConstraintRuleSet.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
