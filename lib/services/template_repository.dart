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

  /// Keyed by [TemplateManifestEntry.file] — whether that bundled file
  /// discloses a real source (see every syllabus file's own `_source`
  /// field). Populated for free while [ensureAllSeeded] already reads
  /// every file's raw content; see [hasRealSource].
  final Map<String, bool> _realSourceByFile = {};

  static const _manifestPath = 'assets/syllabi/manifest.json';

  String _cacheKey(String curriculumCode, String subjectCode, int gradeLevel) =>
      '$curriculumCode|$subjectCode|$gradeLevel';

  /// Lists every curriculum/subject/grade combination bundled with the app.
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
  /// Each file supplies its own curriculum, so bundling templates from both
  /// the 2023 CBC and the 2013 OBC just means listing files from both in the
  /// manifest — no code change needed here.
  ///
  /// Each file is imported independently — one malformed template (a typo
  /// in a hand-edited JSON file, a future asset that doesn't quite match
  /// the expected shape) is logged and skipped rather than aborting the
  /// whole loop, which would otherwise leave every OTHER subject/grade
  /// unseeded too and surface as a raw error on every screen that opens
  /// the subject/grade picker — far too broad a blast radius for one bad
  /// file.
  Future<void> ensureAllSeeded() async {
    final manifest = await loadManifest();
    for (final entry in manifest) {
      try {
        final raw = await rootBundle.loadString('assets/syllabi/${entry.file}');
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _realSourceByFile[entry.file] = _looksLikeRealSource(json);
        await _db.importTemplate(json);
      } catch (error) {
        // ignore: avoid_print
        print('TemplateRepository.ensureAllSeeded: skipping ${entry.file} — $error');
      }
    }
  }

  bool _looksLikeRealSource(Map<String, dynamic> json) =>
      json['_source'] is String && (json['_source'] as String).trim().isNotEmpty;

  /// Whether the bundled file behind [file] (a [TemplateManifestEntry.file])
  /// discloses a real source — false for genuinely non-real placeholder/
  /// seed content. (`english_grade8.json`/`math_grade8.json`, the only
  /// confirmed cases as of 2026-09-04, were removed from the app entirely
  /// that same day — real, user-confirmed: Grade 8 English/Mathematics
  /// were phased out and replaced by Form 1 in the actual curriculum, so
  /// there was never real content to source for them in the first place.
  /// This check remains for whatever future upload turns out the same
  /// way.) Tentative, 2026-09-03: used only to show a "Not Ready"
  /// indicator on subjects that can't yet produce a usable Lesson
  /// Plan/Scheme of Work — never to hide or silently skip content, since a
  /// subject/grade with thin-but-real content should still work, just
  /// imperfectly. Normally answered instantly from what [ensureAllSeeded]
  /// already read; falls back to a direct file check if called before that
  /// for any reason, rather than assuming a file is ready.
  Future<bool> hasRealSource(String file) async {
    if (_realSourceByFile[file] case final known?) return known;
    try {
      final raw = await rootBundle.loadString('assets/syllabi/$file');
      final hasSource = _looksLikeRealSource(jsonDecode(raw) as Map<String, dynamic>);
      _realSourceByFile[file] = hasSource;
      return hasSource;
    } catch (_) {
      return false;
    }
  }

  /// Imports one syllabus template supplied at runtime (e.g. picked up by a
  /// future "import my own subject data" flow) rather than bundled as an
  /// asset. Same JSON shape as the bundled files — see assets/syllabi/ for
  /// examples and `firebase/README.md`-style documentation to follow.
  Future<void> importUserSuppliedTemplate(Map<String, dynamic> json) => _db.importTemplate(json);

  /// Lists every curriculum that's been imported (bundled ones are imported
  /// on every launch by [ensureAllSeeded]).
  Future<List<Curriculum>> listCurricula() => _db.listCurricula();

  /// Returns the syllabus for one subject+grade within one curriculum,
  /// switching instantly between templates once they've been seeded: an
  /// in-memory hit needs no I/O, and a miss is just one indexed local
  /// SQLite query.
  Future<SyllabusTemplate?> loadSyllabus({
    required String curriculumCode,
    required String subjectCode,
    required int gradeLevel,
  }) async {
    final key = _cacheKey(curriculumCode, subjectCode, gradeLevel);
    final cached = _templateCache[key];
    if (cached != null) return cached;

    final template = await _db.getSyllabus(
      curriculumCode: curriculumCode,
      subjectCode: subjectCode,
      gradeLevel: gradeLevel,
    );
    if (template != null) {
      _templateCache[key] = template;
    }
    return template;
  }
}
