import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/data_backup_service.dart';
import '../services/device_downloads_service.dart';

/// "Data Backup" (2026-09-05, per explicit request) — a real, restorable
/// backup of Roster and Marking data, distinct from
/// [ReportClassBackupService]'s existing opportunistic backup-email (a
/// human-readable document, not restorable, and Chief Marker data isn't in
/// it at all). See [DataBackupService]'s own doc comment for exactly
/// what's covered and what's deliberately left for a Stage 2 (script
/// photos).
class DataBackupScreen extends StatefulWidget {
  const DataBackupScreen({super.key, this.backupService, this.downloadsService});

  final DataBackupService? backupService;
  final DeviceDownloadsService? downloadsService;

  @override
  State<DataBackupScreen> createState() => _DataBackupScreenState();
}

class _DataBackupScreenState extends State<DataBackupScreen> {
  late final DataBackupService _backupService = widget.backupService ?? DataBackupService();
  late final DeviceDownloadsService _downloadsService = widget.downloadsService ?? DeviceDownloadsService();

  bool _busy = false;

  Future<void> _backUpNow() async {
    setState(() => _busy = true);
    try {
      final file = await _backupService.exportBackup();
      final fileName = file.uri.pathSegments.last;
      try {
        await _downloadsService.saveToDownloads(file: file, fileName: fileName, mimeType: 'application/zip');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup saved to your Downloads folder. Keep a copy somewhere off this '
              'device too (Google Drive, email to yourself, etc.) — a backup that only lives on this phone '
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
    final picked = File(result.single.path!);

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
            if (!manifest.includesScriptPhotos) ...[
              const SizedBox(height: 8),
              const Text(
                'This backup does not include script photos (not yet covered by backups) — only the marking '
                'data itself.',
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'This REPLACES every class, learner, score, marking scheme, and results list currently on this '
              'device with what\'s in this backup. Anything added since this backup was made will be lost. '
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
                'Backs up your class rosters (including guardian contacts), scores, marking schemes, and marked '
                'results lists into one file you control — separate from the automatic backup-email some classes '
                'already send, which is just a document, not something the app can restore from.',
              ),
              const SizedBox(height: 4),
              Text(
                'Does not yet include the photographed pages of marking scripts themselves — that\'s a planned '
                'follow-up.',
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
                  leading: Icon(Icons.restore, color: Theme.of(context).colorScheme.error),
                  title: const Text('Restore from Backup'),
                  subtitle: const Text('Replaces current data on this device with a backup file you pick'),
                  onTap: _busy ? null : _restoreFromBackup,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
