import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/marking_script.dart';

/// On-device storage for AI-Assisted Marking scripts (see the 9-stage
/// feature spec) — each script's captured page images live in their own
/// subdirectory, with a small JSON catalog alongside for metadata. Fully
/// offline: capturing and storing a script never needs a connection;
/// only later stages (AI grading) will.
class MarkingScriptRepository {
  static const _catalogFileName = 'marking_scripts_catalog.json';
  static const _contentDirName = 'marking_scripts';

  /// Separate top-level directory from [_contentDirName] (not a
  /// subdirectory of a script's own raw-capture folder) — deliberately, so
  /// [discardPhotos]'s recursive delete of the raw-capture directory can
  /// never silently take the stamped/marked artifacts with it. See
  /// [MarkingScript.annotatedPageFileNames].
  static const _annotatedContentDirName = 'marking_scripts_annotated';

  Future<Directory> _rootDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final contentDir = Directory(p.join(dir.path, _contentDirName));
    if (!await contentDir.exists()) await contentDir.create(recursive: true);
    return contentDir;
  }

  Future<Directory> _annotatedRootDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final contentDir = Directory(p.join(dir.path, _annotatedContentDirName));
    if (!await contentDir.exists()) await contentDir.create(recursive: true);
    return contentDir;
  }

  Future<File> _catalogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _catalogFileName));
  }

  Future<MarkingScriptCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return MarkingScriptCatalog.empty();
    try {
      return MarkingScriptCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return MarkingScriptCatalog.empty();
    }
  }

  Future<void> _saveCatalog(MarkingScriptCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  String _slug(String input) {
    final safe = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'script' : safe;
  }

  /// The next free script number, for pre-filling the capture form.
  Future<int> nextScriptNumber() async => (await loadCatalog()).nextScriptNumber;

  /// Copies a burst-capture session's already-cropped/deskewed/enhanced
  /// page image files (from wherever the camera package wrote them) into
  /// this script's own permanent storage, in page order, and records it
  /// in the catalog.
  Future<MarkingScript> saveScript({
    required String firstName,
    required String surname,
    required CandidateGender gender,
    String? studentIdNumber,
    required int scriptNumber,
    required String subjectName,
    required String gradeName,
    String classLevel = '',
    String cohortName = '',
    required List<File> capturedPageFiles,
    List<PreSegmentedAnswer>? preSegmentedAnswers,
  }) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${_slug('$firstName $surname')}';
    final scriptDir = Directory(p.join((await _rootDir()).path, id));
    if (!await scriptDir.exists()) await scriptDir.create(recursive: true);

    final pageFileNames = <String>[];
    for (var i = 0; i < capturedPageFiles.length; i++) {
      final fileName = 'page_${(i + 1).toString().padLeft(2, '0')}.jpg';
      await capturedPageFiles[i].copy(p.join(scriptDir.path, fileName));
      pageFileNames.add(fileName);
    }

    final script = MarkingScript(
      id: id,
      firstName: firstName,
      surname: surname,
      gender: gender,
      studentIdNumber: studentIdNumber,
      scriptNumber: scriptNumber,
      subjectName: subjectName,
      gradeName: gradeName,
      classLevel: classLevel,
      cohortName: cohortName,
      pageFileNames: pageFileNames,
      capturedAt: DateTime.now(),
      preSegmentedAnswers: preSegmentedAnswers,
    );

    final catalog = await loadCatalog();
    await _saveCatalog(MarkingScriptCatalog(scripts: [...catalog.scripts, script]));
    return script;
  }

  /// Full local paths to a script's page images, in page order — for
  /// display, review, or eventual upload to AI grading. Enforced here,
  /// not just documented on the model: once [MarkingScript.photosDiscarded]
  /// is true the files genuinely no longer exist, so this always returns
  /// empty rather than handing back paths to files that were deliberately
  /// deleted (see [discardPhotos]).
  Future<List<File>> pageFilesFor(MarkingScript script) async {
    if (script.photosDiscarded) return [];
    final root = await getApplicationDocumentsDirectory();
    final scriptDir = p.join(root.path, _contentDirName, script.id);
    return [for (final name in script.pageFileNames) File(p.join(scriptDir, name))];
  }

  /// Stage H — deletes a script's captured page images to free storage
  /// while keeping everything else (marks, transcriptions, observations,
  /// status) exactly as-is and retrievable. Irreversible: once the files
  /// are gone there's no undo, so the caller (see MarkingQueueScreen)
  /// confirms with the teacher first and only offers this for scripts
  /// already [MarkingScriptStatus.reviewed] — a script whose grading
  /// still might need a retry (which re-uploads the images) must keep
  /// them.
  Future<MarkingScript> discardPhotos(MarkingScript script) async {
    final root = await getApplicationDocumentsDirectory();
    final scriptDir = Directory(p.join(root.path, _contentDirName, script.id));
    if (await scriptDir.exists()) await scriptDir.delete(recursive: true);

    final updated = script.copyWith(photosDiscarded: true);
    await update(updated);
    return updated;
  }

  Future<void> updateStatus(MarkingScript script, MarkingScriptStatus status) async {
    final catalog = await loadCatalog();
    final updated = [
      for (final s in catalog.scripts) if (s.id == script.id) s.copyWith(status: status) else s,
    ];
    await _saveCatalog(MarkingScriptCatalog(scripts: updated));
  }

  /// Appends an already-fully-formed [script] straight to the catalog —
  /// for records that don't go through [saveScript]'s capture-and-copy
  /// path because there are no per-script page images to store. Unlike
  /// [update], this does add a genuinely new catalog entry rather than
  /// only replacing an existing one.
  Future<void> add(MarkingScript script) async {
    final catalog = await loadCatalog();
    await _saveCatalog(MarkingScriptCatalog(scripts: [...catalog.scripts, script]));
  }

  /// Persists an already-modified [script] (e.g. via [MarkingScript.copyWith])
  /// back to the catalog — for updates richer than just [updateStatus],
  /// like linking a scheme or storing Stage 4's grading results.
  Future<void> update(MarkingScript script) async {
    final catalog = await loadCatalog();
    final updated = [for (final s in catalog.scripts) if (s.id == script.id) script else s];
    await _saveCatalog(MarkingScriptCatalog(scripts: updated));
  }

  Future<void> remove(MarkingScript script) async {
    final root = await getApplicationDocumentsDirectory();
    final scriptDir = Directory(p.join(root.path, _contentDirName, script.id));
    if (await scriptDir.exists()) await scriptDir.delete(recursive: true);
    final annotatedDir = Directory(p.join((await _annotatedRootDir()).path, script.id));
    if (await annotatedDir.exists()) await annotatedDir.delete(recursive: true);

    final catalog = await loadCatalog();
    await _saveCatalog(MarkingScriptCatalog(scripts: catalog.scripts.where((s) => s.id != script.id).toList()));
  }

  /// Copies Concise Marking's freshly-generated tick/cross-annotated pages,
  /// performance-report PDF and (when the engine produced one) fallback
  /// reproduction PDF into this script's own PERMANENT annotated-artifacts
  /// directory, and persists the resulting file names onto the script
  /// (owner request, 2026-09-28 — see [MarkingScript.annotatedPageFileNames]
  /// for why this is a separate directory from the raw captures). [source]
  /// files themselves are left untouched — the caller's own temp copies, if
  /// any, are still the caller's to clean up.
  Future<MarkingScript> saveAnnotatedArtifacts({
    required MarkingScript script,
    required List<File> annotatedPages,
    required File reportPdf,
    File? fallbackPdf,
  }) async {
    final scriptDir = Directory(p.join((await _annotatedRootDir()).path, script.id));
    if (!await scriptDir.exists()) await scriptDir.create(recursive: true);

    final annotatedFileNames = <String>[];
    for (var i = 0; i < annotatedPages.length; i++) {
      final fileName = 'annotated_${(i + 1).toString().padLeft(2, '0')}.jpg';
      await annotatedPages[i].copy(p.join(scriptDir.path, fileName));
      annotatedFileNames.add(fileName);
    }

    const reportFileName = 'report.pdf';
    await reportPdf.copy(p.join(scriptDir.path, reportFileName));

    String? fallbackFileName;
    if (fallbackPdf != null) {
      fallbackFileName = 'fallback.pdf';
      await fallbackPdf.copy(p.join(scriptDir.path, fallbackFileName));
    }

    final updated = script.copyWith(
      annotatedPageFileNames: annotatedFileNames,
      reportPdfFileName: reportFileName,
      fallbackPdfFileName: fallbackFileName,
      clearFallbackPdfFileName: fallbackFileName == null,
    );
    await update(updated);
    return updated;
  }

  /// The stamped/marked copy of a script's pages, reconstructed from
  /// [MarkingScript.annotatedPageFileNames] — empty until Concise Marking
  /// has run (or for a script marked another way). Never affected by
  /// [MarkingScript.photosDiscarded]: that flag only ever concerns the raw
  /// captures in [pageFilesFor], not these separately-stored artifacts.
  Future<List<File>> annotatedPageFilesFor(MarkingScript script) async {
    final scriptDir = p.join((await _annotatedRootDir()).path, script.id);
    return [for (final name in script.annotatedPageFileNames) File(p.join(scriptDir, name))];
  }

  Future<File?> reportPdfFileFor(MarkingScript script) async {
    final name = script.reportPdfFileName;
    if (name == null) return null;
    return File(p.join((await _annotatedRootDir()).path, script.id, name));
  }

  Future<File?> fallbackPdfFileFor(MarkingScript script) async {
    final name = script.fallbackPdfFileName;
    if (name == null) return null;
    return File(p.join((await _annotatedRootDir()).path, script.id, name));
  }
}
