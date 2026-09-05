import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

/// A real, restorable backup for the app's on-device Roster and Marking
/// data (2026-09-05, per explicit request) — everything
/// [ReportClassBackupService] does NOT cover: that service only emails a
/// human-readable Broad Mark Sheet *document* to a class's backup address,
/// which can't be fed back into the app to restore anything, and it never
/// touches Chief Marker's data at all.
///
/// This bundles into one shareable `.zip`:
///  - the Report Form Pipeline's real SQLite rows (classes, learners incl.
///    guardian contacts, subjects, scores) — restorable as exact rows, not
///    a document;
///  - every on-device JSON sidecar: marking scripts catalog, marking
///    schemes catalog, marked results lists, roster-upload-session state,
///    subject-teacher names, and any in-progress marking-key draft;
///  - **(2026-09-05, Stage 2)** every marking script's actual photographed
///    pages — [MarkingScriptRepository]'s catalog JSON only records each
///    script's PAGE FILE NAMES, the image bytes live as separate files
///    under `marking_scripts/<scriptId>/` in app storage, and those are
///    the one genuinely irreplaceable asset here (re-grading needs the
///    real photographed paper, which a teacher may not still have). Left
///    out of the very first version only so a first working backup didn't
///    have to wait on it; a real class's script photos are usually a few
///    MB per script, so this can make the zip meaningfully larger — the
///    manifest reports a real byte count so the UI can say so honestly.
///
/// **Restore is destructive by design**: every table/file/photo this
/// covers is fully REPLACED, not merged, with the backup's content —
/// matching what "restore my data" means in practice (a new/repaired
/// device, or deliberately rolling back). Restoring script photos deletes
/// the ENTIRE existing `marking_scripts/` photo directory first, so a
/// script that existed on-device but isn't in this particular backup
/// loses its photos too — same "full replace, not merge" rule as
/// everything else here. The calling screen is responsible for a clear
/// confirmation before calling [importBackup]; this service itself does
/// not ask.
class DataBackupService {
  DataBackupService({DatabaseHelper? databaseHelper}) : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _dbHelper;

  /// Bump this if the bundled shape ever changes in a way an older
  /// [importBackup] couldn't handle correctly — [importBackup] refuses any
  /// backup whose version is newer than it understands, rather than
  /// silently importing a shape it wasn't built for. Version 2 added
  /// script photos (`script_photos/<scriptId>/<fileName>` entries); an
  /// older app importing a v2 backup would restore everything else fine
  /// but simply never look for those entries, silently missing the
  /// photos — which is why the version is bumped at all, so a mismatch is
  /// at least visible rather than assumed compatible.
  static const _formatVersion = 2;

  /// Parent-to-child order — matters for [importBackup]'s insert order
  /// (foreign keys are turned off for the restore transaction regardless,
  /// see there, but keeping this order is still the honest, readable one).
  static const _tableNames = ['report_classes', 'report_learners', 'report_subjects', 'report_scores'];

  static const _sidecarFileNames = [
    'marking_scripts_catalog.json',
    'marking_schemes_catalog.json',
    'marked_results_lists_catalog.json',
    'roster_upload_sessions.json',
    'subject_teachers.json',
    'pending_marking_key_draft.json',
  ];

  /// Matches MarkingScriptRepository's own private constant — script photo
  /// directories live at `<app documents dir>/$_scriptsContentDirName/<scriptId>/`.
  static const _scriptsContentDirName = 'marking_scripts';

  /// Builds the backup zip and writes it into the app's own documents
  /// directory (not a public folder — the caller decides whether/how to
  /// hand it to the user, e.g. DeviceDownloadsService or the share sheet,
  /// same pattern every other generated document in this app already
  /// uses). Returns the written file.
  Future<File> exportBackup() async {
    final db = await _dbHelper.database;
    final archive = Archive();

    void addJson(String name, Object? value) {
      final bytes = utf8.encode(jsonEncode(value));
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    var scriptCount = 0;
    var classCount = 0;
    for (final table in _tableNames) {
      final rows = await db.query(table);
      if (table == 'report_classes') classCount = rows.length;
      addJson('tables/$table.json', rows);
    }

    final dir = await getApplicationDocumentsDirectory();
    final includedSidecars = <String>[];
    List<dynamic>? scripts;
    for (final fileName in _sidecarFileNames) {
      final file = File(p.join(dir.path, fileName));
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile('sidecars/$fileName', bytes.length, bytes));
      includedSidecars.add(fileName);
      if (fileName == 'marking_scripts_catalog.json') {
        try {
          scripts = (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)['scripts'] as List?;
          scriptCount = scripts?.length ?? 0;
        } catch (_) {
          // Manifest counts are informational only — a malformed catalog
          // still gets backed up byte-for-byte above, just without a count.
        }
      }
    }

    // Script photos — see this class's own doc comment on why these
    // matter most. Only ever reads files the catalog itself references
    // (never globs the whole directory), so a script whose photos were
    // already discarded (MarkingScript.photosDiscarded) is simply skipped,
    // not treated as an error.
    var photoBytes = 0;
    var photoCount = 0;
    if (scripts != null) {
      for (final scriptJson in scripts.cast<Map<String, dynamic>>()) {
        final scriptId = scriptJson['id'] as String?;
        final pageFileNames = (scriptJson['pageFileNames'] as List?)?.cast<String>() ?? const [];
        if (scriptId == null) continue;
        for (final fileName in pageFileNames) {
          final file = File(p.join(dir.path, _scriptsContentDirName, scriptId, fileName));
          if (!await file.exists()) continue;
          final bytes = await file.readAsBytes();
          archive.addFile(ArchiveFile('script_photos/$scriptId/$fileName', bytes.length, bytes));
          photoBytes += bytes.length;
          photoCount++;
        }
      }
    }

    addJson('manifest.json', {
      'format_version': _formatVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'includes_script_photos': true,
      'script_photo_count': photoCount,
      'script_photo_bytes': photoBytes,
      'report_class_count': classCount,
      'marking_script_count': scriptCount,
      'included_sidecar_files': includedSidecars,
    });

    final zipBytes = ZipEncoder().encode(archive);
    final timestamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final outFile = File(p.join(dir.path, 'smart_teacher_backup_$timestamp.zip'));
    await outFile.writeAsBytes(zipBytes, flush: true);
    return outFile;
  }

  /// Reads back a zip made by [exportBackup] without touching anything —
  /// for the confirmation screen to show what a backup file actually
  /// contains before the teacher commits to overwriting current data.
  Future<BackupManifest> readManifest(File zipFile) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException('This doesn\'t look like a Smart Teacher backup file.');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>)) as Map<String, dynamic>;
    final formatVersion = manifest['format_version'] as int? ?? 0;
    if (formatVersion > _formatVersion) {
      throw FormatException(
        'This backup was made by a newer version of the app (format $formatVersion) than this one understands '
        '(format $_formatVersion). Update the app before restoring it.',
      );
    }
    return BackupManifest(
      exportedAt: DateTime.parse(manifest['exported_at'] as String),
      reportClassCount: manifest['report_class_count'] as int? ?? 0,
      markingScriptCount: manifest['marking_script_count'] as int? ?? 0,
      includesScriptPhotos: manifest['includes_script_photos'] as bool? ?? false,
      scriptPhotoCount: manifest['script_photo_count'] as int? ?? 0,
      scriptPhotoBytes: manifest['script_photo_bytes'] as int? ?? 0,
    );
  }

  /// Replaces every table/file this backup covers with the zip's content.
  /// See this class's own doc comment — deliberately destructive, and
  /// deliberately not asking for confirmation itself; the caller already
  /// did that via [readManifest] before calling this.
  Future<void> importBackup(File zipFile) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) {
      throw const FormatException('This doesn\'t look like a Smart Teacher backup file.');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>)) as Map<String, dynamic>;
    final formatVersion = manifest['format_version'] as int? ?? 0;
    if (formatVersion > _formatVersion) {
      throw FormatException('This backup (format $formatVersion) is newer than this app version supports.');
    }

    final db = await _dbHelper.database;
    // Foreign keys are turned off for the restore only — report_subjects
    // has self-referencing composite-subject columns, and restoring rows
    // in whatever order the backup stored them shouldn't have to depend on
    // parts always sorting before the composites that reference them.
    // Restored to ON immediately after, matching DatabaseHelper's own
    // onConfigure setting for every other moment in the app's life.
    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((txn) async {
        for (final table in _tableNames.reversed) {
          await txn.delete(table);
        }
        for (final table in _tableNames) {
          final tableFile = archive.findFile('tables/$table.json');
          if (tableFile == null) continue;
          final rows = (jsonDecode(utf8.decode(tableFile.content as List<int>)) as List).cast<Map<String, dynamic>>();
          for (final row in rows) {
            await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      });
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }

    final dir = await getApplicationDocumentsDirectory();
    for (final fileName in _sidecarFileNames) {
      final entry = archive.findFile('sidecars/$fileName');
      if (entry == null) continue;
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(entry.content as List<int>, flush: true);
    }

    // Script photos — full replace, same rule as everything else here
    // (see this class's own doc comment): the whole existing photo
    // directory is removed first, so a script that isn't in THIS backup
    // doesn't keep orphaned photos lying around after its catalog entry
    // has just been overwritten above.
    final scriptsDir = Directory(p.join(dir.path, _scriptsContentDirName));
    if (await scriptsDir.exists()) await scriptsDir.delete(recursive: true);
    // Every entry ever added to this archive is a real file (see
    // exportBackup — no directory placeholder entries are ever added), so
    // no separate "is this a file" filter is needed here.
    final photoEntries = archive.files.where((f) => f.name.startsWith('script_photos/'));
    for (final entry in photoEntries) {
      final relativePath = entry.name.substring('script_photos/'.length);
      final outFile = File(p.join(dir.path, _scriptsContentDirName, relativePath));
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>, flush: true);
    }
  }
}

class BackupManifest {
  final DateTime exportedAt;
  final int reportClassCount;
  final int markingScriptCount;
  final bool includesScriptPhotos;
  final int scriptPhotoCount;
  final int scriptPhotoBytes;

  const BackupManifest({
    required this.exportedAt,
    required this.reportClassCount,
    required this.markingScriptCount,
    required this.includesScriptPhotos,
    this.scriptPhotoCount = 0,
    this.scriptPhotoBytes = 0,
  });
}
