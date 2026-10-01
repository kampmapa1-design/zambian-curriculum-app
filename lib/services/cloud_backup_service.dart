import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'auth_service.dart';

class CloudBackupUnavailable implements Exception {
  final String message;
  const CloudBackupUnavailable(this.message);
  @override
  String toString() => message;
}

/// One backup file already sitting in this teacher's own Cloud Storage
/// folder — [name] is the exact file name [DataBackupService.exportBackup]
/// gave it (its own ISO timestamp), so a listing reads the same as a local
/// one would.
class CloudBackupEntry {
  final String name;
  final Reference ref;
  final DateTime? createdAt;
  final int? sizeBytes;

  const CloudBackupEntry({required this.name, required this.ref, this.createdAt, this.sizeBytes});
}

/// The off-device half of [DataBackupService] (added 2026-09-18, the app
/// status report's reliability recommendation) — the local export/
/// import/restore engine is untouched; this only adds a second place the
/// same zip also goes, and a way to pull one back down. Every operation is
/// scoped to the signed-in teacher's own uid (see storage.rules'
/// `backups/{uid}/` rule) — never a cross-teacher listing, and Storage
/// itself enforces that even if a bug here didn't.
class CloudBackupService {
  CloudBackupService({FirebaseStorage? storage}) : _providedStorage = storage;

  // Lazy, same reasoning as PhotoBatchService/TopicSearchService's own
  // doc comments: resolving FirebaseStorage.instance needs
  // Firebase.initializeApp() to have already run.
  final FirebaseStorage? _providedStorage;
  FirebaseStorage get _storage => _providedStorage ?? FirebaseStorage.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<Reference> _backupsFolder() async {
    final user = await AuthService.instance.ensureSignedIn();
    return _storage.ref('backups/${user.uid}');
  }

  /// Uploads [zipFile] (already built by [DataBackupService.exportBackup])
  /// to this teacher's own Storage folder, keeping its exact file name.
  Future<void> uploadBackup(File zipFile) async {
    if (!await isOnline) {
      throw const CloudBackupUnavailable("You're offline. Connect to the internet to back up to the cloud.");
    }
    final folder = await _backupsFolder();
    final fileName = p.basename(zipFile.path);
    try {
      await folder.child(fileName).putFile(zipFile, SettableMetadata(contentType: 'application/zip'));
    } on FirebaseException catch (e) {
      throw CloudBackupUnavailable(e.message ?? 'Could not upload the backup.');
    }
  }

  /// Every backup this teacher has in the cloud, most recent first — the
  /// file name itself already encodes the export timestamp, but metadata's
  /// own `timeCreated` is used for sorting since it's always present even
  /// if a file name were ever hand-renamed.
  Future<List<CloudBackupEntry>> listBackups() async {
    if (!await isOnline) {
      throw const CloudBackupUnavailable("You're offline. Connect to the internet to see your cloud backups.");
    }
    final folder = await _backupsFolder();
    final ListResult result;
    try {
      result = await folder.listAll();
    } on FirebaseException catch (e) {
      throw CloudBackupUnavailable(e.message ?? 'Could not list your cloud backups.');
    }
    final entries = <CloudBackupEntry>[];
    for (final ref in result.items) {
      FullMetadata? metadata;
      try {
        metadata = await ref.getMetadata();
      } on FirebaseException {
        metadata = null; // Still listable, just without a size/date shown.
      }
      entries.add(CloudBackupEntry(name: ref.name, ref: ref, createdAt: metadata?.timeCreated, sizeBytes: metadata?.size));
    }
    entries.sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    return entries;
  }

  /// Downloads [entry] into a local temp file, ready for
  /// [DataBackupService.readManifest]/[DataBackupService.importBackup] to
  /// consume exactly like a locally-picked file — the restore flow itself
  /// doesn't need to know whether a backup came from the cloud or a file
  /// picker.
  Future<File> downloadBackup(CloudBackupEntry entry) async {
    if (!await isOnline) {
      throw const CloudBackupUnavailable("You're offline. Connect to the internet to restore this backup.");
    }
    final dir = await getTemporaryDirectory();
    final outFile = File(p.join(dir.path, entry.name));
    try {
      await entry.ref.writeToFile(outFile);
    } on FirebaseException catch (e) {
      throw CloudBackupUnavailable(e.message ?? 'Could not download this backup.');
    }
    return outFile;
  }

  /// Keeps only the [keep] most recent cloud backups, deleting older ones
  /// — without this, a recurring automatic backup would grow a teacher's
  /// Storage usage without bound. Best-effort: a failed listing or delete
  /// is swallowed rather than surfaced — the backup that triggered this
  /// call already succeeded; cleanup failing is not itself a data-loss
  /// risk, just a storage-cost one.
  Future<void> pruneOldBackups({int keep = 14}) async {
    List<CloudBackupEntry> entries;
    try {
      entries = await listBackups();
    } catch (_) {
      return;
    }
    if (entries.length <= keep) return;
    for (final entry in entries.skip(keep)) {
      try {
        await entry.ref.delete();
      } catch (_) {
        // Best-effort — see this method's own doc comment.
      }
    }
  }
}
