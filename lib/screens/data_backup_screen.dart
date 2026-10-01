import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/cloud_backup_scheduler.dart';
import '../services/cloud_backup_service.dart';
import '../services/data_backup_service.dart';
import '../services/device_downloads_service.dart';

/// "Data Backup" (2026-09-05, per explicit request) — a real, restorable
/// backup of Roster and Marking data, distinct from
/// [ReportClassBackupService]'s existing opportunistic backup-email (a
/// human-readable document, not restorable, and Chief Marker data isn't in
/// it at all). See [DataBackupService]'s own doc comment for exactly
/// what's covered — including, as of the same day, every marking script's
/// actual photographed pages, not just the marking data around them.
class DataBackupScreen extends StatefulWidget {
  const DataBackupScreen({
    super.key,
    this.backupService,
    this.downloadsService,
    this.cloudBackupService,
    this.cloudScheduler,
  });

  final DataBackupService? backupService;
  final DeviceDownloadsService? downloadsService;
  final CloudBackupService? cloudBackupService;
  final CloudBackupScheduler? cloudScheduler;

  @override
  State<DataBackupScreen> createState() => _DataBackupScreenState();
}

class _DataBackupScreenState extends State<DataBackupScreen> {
  late final DataBackupService _backupService = widget.backupService ?? DataBackupService();
  late final DeviceDownloadsService _downloadsService = widget.downloadsService ?? DeviceDownloadsService();
  late final CloudBackupService _cloudBackupService = widget.cloudBackupService ?? CloudBackupService();
  late final CloudBackupScheduler _cloudScheduler = widget.cloudScheduler ?? CloudBackupScheduler();

  bool _busy = false;
  DateTime? _lastCloudBackupAt;

  @override
  void initState() {
    super.initState();
    _loadLastCloudBackupTime();
  }

  Future<void> _loadLastCloudBackupTime() async {
    final last = await _cloudScheduler.lastSuccessfulBackupAt();
    if (!mounted) return;
    setState(() => _lastCloudBackupAt = last);
  }

  Future<void> _backUpNow() async {
    setState(() => _busy = true);
    try {
      final file = await _backupService.exportBackup();
      final sizeLabel = _formatBytes(await file.length());
      final fileName = file.uri.pathSegments.last;
      try {
        await _downloadsService.saveToDownloads(file: file, fileName: fileName, mimeType: 'application/zip');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup saved to your Downloads folder ($sizeLabel). Keep a copy somewhere off '
              'this device too (Google Drive, email to yourself, etc.) — a backup that only lives on this phone '
              'doesn\'t protect against losing this phone.')),
        );
      } on DeviceDownloadsUnsupported {
        if (!mounted) return;
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Smart Teacher data backup'));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create backup: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromBackup() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (result.isEmpty || !mounted) return;
    await _confirmAndRestore(File(result.single.path!));
  }

  /// Shared by both restore paths (a locally-picked file, or one just
  /// downloaded from the cloud) — everything from reading the manifest
  /// through the destructive-confirmation dialog to the actual restore is
  /// identical either way; only how [picked] was obtained differs.
  Future<void> _confirmAndRestore(File picked) async {
    setState(() => _busy = true);
    BackupManifest manifest;
    try {
      manifest = await _backupService.readManifest(picked);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Made ${_formatDateTime(manifest.exportedAt)}'),
            const SizedBox(height: 8),
            Text('${manifest.reportClassCount} class(es), ${manifest.markingScriptCount} marked script(s).'),
            if (manifest.includesScriptPhotos && manifest.scriptPhotoCount > 0) ...[
              const SizedBox(height: 4),
              Text('Includes ${manifest.scriptPhotoCount} script photo(s), ${_formatBytes(manifest.scriptPhotoBytes)}.'),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                'This backup does not include script photos — only the marking data around them.',
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'This REPLACES every class, learner, score, marking scheme, results list, and script photo currently '
              'on this device with what\'s in this backup. Anything added since this backup was made will be lost. '
              'This cannot be undone.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Replace Current Data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await _backupService.importBackup(picked);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Restore complete'),
          content: const Text('Close and reopen the app now so every screen picks up the restored data.'),
          actions: [
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore failed: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backUpToCloud() async {
    setState(() => _busy = true);
    try {
      await _cloudScheduler.backUpNowToCloud();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backed up to the cloud. Restorable on this or any other signed-in device.')),
      );
      await _loadLastCloudBackupTime();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cloud backup failed: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromCloud() async {
    setState(() => _busy = true);
    List<CloudBackupEntry> entries;
    try {
      entries = await _cloudBackupService.listBackups();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No cloud backups found for this account yet.')));
      return;
    }

    final chosen = await showModalBottomSheet<CloudBackupEntry>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Choose a cloud backup to restore', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final entry in entries)
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(entry.createdAt == null ? entry.name : _formatDateTime(entry.createdAt!)),
                subtitle: entry.sizeBytes == null ? null : Text(_formatBytes(entry.sizeBytes!)),
                onTap: () => Navigator.of(sheetContext).pop(entry),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    setState(() => _busy = true);
    File downloaded;
    try {
      downloaded = await _cloudBackupService.downloadBackup(chosen);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _confirmAndRestore(downloaded);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Backup')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: Opacity(
          opacity: _busy ? 0.6 : 1,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Backs up your class rosters (including guardian contacts), scores, marking schemes, marked '
                'results lists, and every marking script\'s photographed pages into one file you control — '
                'separate from the automatic backup-email some classes already send, which is just a document, '
                'not something the app can restore from.',
              ),
              const SizedBox(height: 4),
              Text(
                'Script photos can make this a large file — expect a noticeable wait for a class with many '
                'marked scripts.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('Back Up Now'),
                  subtitle: const Text('Creates a backup file and saves it to your Downloads folder'),
                  trailing: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                  onTap: _busy ? null : _backUpNow,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('Back Up to Cloud'),
                  subtitle: Text(
                    _lastCloudBackupAt == null
                        ? 'Not backed up to the cloud yet — also happens automatically once a day when you open the app'
                        : 'Last backed up ${_formatDateTime(_lastCloudBackupAt!)} — also happens automatically once a day',
                  ),
                  onTap: _busy ? null : _backUpToCloud,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: Icon(Icons.restore_outlined, color: Theme.of(context).colorScheme.error),
                  title: const Text('Restore from Backup'),
                  subtitle: const Text('Replaces current data on this device with a backup file you pick'),
                  onTap: _busy ? null : _restoreFromBackup,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: Icon(Icons.cloud_download_outlined, color: Theme.of(context).colorScheme.error),
                  title: const Text('Restore from Cloud'),
                  subtitle: const Text('Replaces current data on this device with a backup from your cloud account'),
                  onTap: _busy ? null : _restoreFromCloud,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
