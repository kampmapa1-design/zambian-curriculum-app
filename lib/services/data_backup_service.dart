import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

/// Stage 1 of a real, restorable backup for the app's on-device Roster and
/// Marking data (2026-09-05, per explicit request) — everything
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
///    subject-teacher names, and any in-progress marking-key draft.
///
/// **Deliberately NOT included yet** (Stage 2, a real follow-up, not
/// forgotten): the actual photographed pages of every marking script.
/// [MarkingScriptRepository]'s catalog JSON only records each script's
/// PAGE FILE NAMES, not the image bytes — those live as separate files on
/// disk and can add up to a genuinely large amount of data across many
/// scripts. Bundling them is the natural next step, kept separate so a
/// first working backup doesn't wait on it.
///
/// **Restore is destructive by design**: every table/file this covers is
/// fully REPLACED, not merged, with the backup's content — matching what
/// "restore my data" means in practice (a new/repaired device, or
/// deliberately rolling back). The calling screen is responsible for a
/// clear confirmation before calling [importBackup]; this service itself
/// does not ask.
class DataBackupService {
  DataBackupService({DatabaseHelper? databaseHelper}) : _dbHelper = databaseHelper ?? DatabaseHelper.instance;

  final DatabaseHelper _dbHelper;

  /// Bump this if the bundled shape ever changes in a way an older
  /// [importBackup] couldn't handle correctly — [importBackup] refuses any
  /// backup whose version is newer than it understands, rather than
  /// silently importing a shape it wasn't built for.
  static const _formatVersion = 1;

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
    for (final fileName in _sidecarFileNames) {
      final file = File(p.join(dir.path, fileName));
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile('sidecars/$fileName', bytes.length, bytes));
      includedSidecars.add(fileName);
      if (fileName == 'marking_scripts_catalog.json') {
        try {
          scriptCount = ((jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)['scripts'] as List?)?.length ?? 0;
        } catch (_) {
          // Manifest counts are informational only — a malformed catalog
          // still gets backed up byte-for-byte above, just without a count.
        }
      }
    }

    addJson('manifest.json', {
      'format_version': _formatVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'includes_script_photos': false,
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
  }
}

class BackupManifest {
  final DateTime exportedAt;
  final int reportClassCount;
  final int markingScriptCount;
  final bool includesScriptPhotos;

  const BackupManifest({
    required this.exportedAt,
    required this.reportClassCount,
    required this.markingScriptCount,
    required this.includesScriptPhotos,
  });
}
