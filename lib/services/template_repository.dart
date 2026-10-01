import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

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
  /// every file's raw content; see [hasRealSource]. Static — see
  /// [_seededThisProcess]'s own doc comment for why.
  static final Map<String, bool> _realSourceByFile = {};

  /// Whether [ensureAllSeeded] has already run once in this app process.
  /// Real, reported bug (2026-09-04): every subject/grade picker screen
  /// calls [ensureAllSeeded] in its own `initState`, and a fresh
  /// `TemplateRepository()` is constructed per screen — so re-opening
  /// "Generate Scheme of Work" (or any other topic picker) from the home
  /// button re-ran the FULL ~60-file import (each file doing dozens of
  /// small SQLite SELECT/INSERT calls per topic/sub-topic/objective/
  /// competency) every single time, even though the bundled asset content
  /// never changes within one running app — reported as "yielding of
  /// subjects takes too long". Static so it holds regardless of how many
  /// `TemplateRepository` instances get created; a real app restart (new
  /// process) naturally reseeds, which is correct since that's the only
  /// time the bundled assets could have changed (a new app version).
  /// [_seedingInFlight] additionally makes concurrent first-calls (e.g. two
  /// screens both mounting at once) await the same single import instead
  /// of racing two full imports against each other.
  static bool _seededThisProcess = false;
  static Future<void>? _seedingInFlight;

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
  /// Bump whenever a bundled syllabus asset changes in a way that needs
  /// re-importing (new subject/grade file, corrected content) — see
  /// [ensureAllSeeded]'s persisted-skip check below. `importTemplate` is
  /// get-or-create per row, so re-running the full import is always safe
  /// (never duplicates); this version number only controls whether it's
  /// SKIPPED, never whether it would be correct to run.
  static const _seedSchemaVersion = 1;
  static const _seedVersionPrefsKey = 'template_repository_seeded_schema_version';

  Future<void> ensureAllSeeded() async {
    if (_seededThisProcess) return;
    if (_seedingInFlight case final inFlight?) return inFlight;
    final future = _ensureAllSeededOncePerVersion();
    _seedingInFlight = future;
    try {
      await future;
      _seededThisProcess = true;
    } finally {
      _seedingInFlight = null;
    }
  }

  /// Real, reported "subject list takes too long to appear" complaint
  /// (2026-09-28): [_seededThisProcess] only ever avoided re-seeding
  /// WITHIN one running app process — every fresh cold start is a new
  /// process, so the full ~60-file import (see [_doEnsureAllSeeded]'s own
  /// doc on why it's paced, not just slow) ran again on literally every
  /// single app launch, even though the bundled assets are byte-identical
  /// to the previous launch. Persisted across launches now: skip the full
  /// import when a PRIOR launch already completed it at this exact
  /// [_seedSchemaVersion] AND the database still genuinely has that data —
  /// never trust the persisted flag alone, since a cleared/corrupted local
  /// DB with a stale flag would otherwise leave every subject picker
  /// silently empty with no re-import to recover it.
  Future<void> _ensureAllSeededOncePerVersion() async {
    // SharedPreferences itself is optional here, not load-bearing: a real
    // app always has it, but the existing test suite calls
    // ensureAllSeeded() directly against a real SQLite DB with no platform
    // channel available for it (no test in this codebase ever needed to
    // mock it before this optimization) — falling back to always-reseed
    // (the exact prior behavior, just slower) is always safe/correct, so
    // a missing/unavailable prefs plugin is never treated as a hard error.
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null;
    }
    if (prefs != null && prefs.getInt(_seedVersionPrefsKey) == _seedSchemaVersion) {
      final curricula = await _db.listCurricula();
      if (curricula.isNotEmpty) return;
    }
    await _doEnsureAllSeeded();
    await prefs?.setInt(_seedVersionPrefsKey, _seedSchemaVersion);
  }

  Future<void> _doEnsureAllSeeded() async {
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
      // A real, reported "app isn't responding" freeze (2026-09-23) — on a
      // fresh install/first launch, this loop runs for every one of the
      // ~60 bundled files back to back. Each iteration's own work
      // (jsonDecode on a real syllabus file, then dozens of small SQLite
      // calls in importTemplate) is individually quick, but async/await
      // does NOT hand control back to Flutter's own frame/input scheduler
      // between iterations unless something actually suspends — and every
      // step here (rootBundle.loadString, sqflite calls) can resolve
      // near-instantly from cache/small files, meaning the loop can run
      // dozens of iterations essentially back-to-back with no real
      // scheduler gap, long enough on a modest device to trip Android's
      // ANR watchdog even though the Dart side was always "making
      // progress". This explicit yield (a real microtask/event-loop gap
      // even when the loop body itself resolved instantly) guarantees
      // Flutter gets a turn to draw a frame / handle a pending touch
      // between every file, not just when the file's own work happens to
      // be slow.
      await Future<void>.delayed(Duration.zero);
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
