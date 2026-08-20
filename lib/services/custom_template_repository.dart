import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/lesson_plan.dart';

/// Persists user-uploaded lesson plan templates (Stage 3: "Upload My Own
/// Template") alongside the bundled CDC default, entirely on-device — no
/// network, no server. Stored as JSON in shared_preferences since this is
/// a handful of small template definitions, not syllabus-sized data.
class CustomTemplateRepository {
  static const _key = 'custom_lesson_plan_templates';

  Future<List<LessonPlanTemplate>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return [for (final json in decoded) LessonPlanTemplate.fromJson(json)];
  }

  Future<void> save(LessonPlanTemplate template) async {
    final templates = await list();
    final withoutExisting = templates.where((t) => t.id != template.id).toList();
    await _persist([...withoutExisting, template]);
  }

  Future<void> delete(String id) async {
    final templates = await list();
    await _persist(templates.where((t) => t.id != id).toList());
  }

  Future<void> _persist(List<LessonPlanTemplate> templates) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final t in templates) t.toJson()]));
  }
}
