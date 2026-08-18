import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/syllabus_models.dart';
import 'database_helper.dart';

/// Bridges the bundled asset templates (assets/syllabi/*.json) and local
/// SQLite storage. All data ships inside the app, so every method here works
/// with no network access.
class TemplateRepository {
  TemplateRepository({DatabaseHelper? databaseHelper})
      : _db = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _db;

  List<TemplateManifestEntry>? _manifestCache;
  final Map<String, SyllabusTemplate> _templateCache = {};

  static const _manifestPath = 'assets/syllabi/manifest.json';

  String _cacheKey(String subjectCode, int gradeLevel) => '$subjectCode|$gradeLevel';

  /// Lists every subject/grade combination bundled with the app.
  Future<List<TemplateManifestEntry>> loadManifest() async {
    if (_manifestCache != null) return _manifestCache!;
    final raw = await rootBundle.loadString(_manifestPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _manifestCache = (json['templates'] as List)
        .cast<Map<String, dynamic>>()
        .map(TemplateManifestEntry.fromJson)
        .toList();
    return _manifestCache!;
  }

  /// Imports every bundled template into local storage. Idempotent and fast
  /// enough to call on every app start (small JSON files, indexed lookups).
  Future<void> ensureAllSeeded() async {
    final manifest = await loadManifest();
    for (final entry in manifest) {
      final raw = await rootBundle.loadString('assets/syllabi/${entry.file}');
      await _db.importTemplate(jsonDecode(raw) as Map<String, dynamic>);
    }
  }

  /// Returns the syllabus for one subject+grade, switching instantly between
  /// templates once they've been seeded: an in-memory hit needs no I/O, and
  /// a miss is just one indexed local SQLite query.
  Future<SyllabusTemplate?> loadSyllabus({
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final key = _cacheKey(subjectCode, gradeLevel);
    final cached = _templateCache[key];
    if (cached != null) return cached;

    final template = await _db.getSyllabus(subjectCode: subjectCode, gradeLevel: gradeLevel);
    if (template != null) {
      _templateCache[key] = template;
    }
    return template;
  }
}
