import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_backup_service.dart';
import 'data_backup_service.dart';

/// The "automatic on a schedule" half of the cloud backup feature
/// (Reliability recommendation, 2026-09-18). This app has no OS-level
/// scheduled-task plugin (WorkManager or equivalent) anywhere yet, and
/// adding one is a real native-platform integration — its own Android
/// manifest entries, its own battery/Doze-mode interaction — that a
/// session without a real multi-day device to test against cannot verify
/// actually fires days later, only that it compiles. Instead, matching
/// this app's own already-established pattern for "check something
/// periodically without a real background scheduler" (see
/// CdcNewMaterialsBanner's weekly opportunistic sync-check), this runs a
/// real check on every app open: if at least [minInterval] has passed
/// since the last successful cloud backup AND the device is online right
/// now, it silently backs up in the background. A teacher who opens the
/// app daily gets a genuinely daily cloud backup; one who opens it less
/// often still never goes longer than [minInterval] past their last visit
/// without a fresh cloud copy.
class CloudBackupScheduler {
  CloudBackupScheduler({DataBackupService? backupService, CloudBackupService? cloudService})
      : _backupService = backupService ?? DataBackupService(),
        _cloudService = cloudService ?? CloudBackupService();

  static const _lastBackupKey = 'cloud_backup_last_success_at';
  static const _inProgressKey = 'cloud_backup_attempt_in_progress';
  static const _skipUntilKey = 'cloud_backup_skip_until';
  static const _backoffAfterCrash = Duration(days: 3);

  final DataBackupService _backupService;
  final CloudBackupService _cloudService;

  /// The last time an automatic (or manual) cloud backup actually
  /// succeeded — surfaced so the Data Backup screen can show a real "Last
  /// backed up ..." line instead of no signal at all.
  Future<DateTime?> lastSuccessfulBackupAt() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_lastBackupKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Call once, fire-and-forget, from the home screen's own init — never
  /// awaited by its caller. Same "never blocks, never throws to its
  /// caller" discipline as [ReportClassBackupService]: a failed automatic
  /// backup must never interrupt or alarm a teacher just opening the app.
  /// The manual "Back Up to Cloud" button (Data Backup screen) surfaces
  /// real errors instead, for a teacher who wants to know right away.
  Future<void> maybeBackUpInBackground({
    Duration minInterval = const Duration(days: 1),
    Duration startDelay = const Duration(seconds: 45),
  }) async {
    // Hardened 2026-09-26 after a real "app crashes 5-10 seconds after
    // opening, on every launch" report. Three protections:
    //  1. Wait [startDelay] so the backup never competes with the app's
    //     own start-up work and the teacher's first taps.
    //  2. The automatic backup excludes script photos (they are by far
    //     the biggest part, and the manual "Back Up to Cloud" button
    //     still includes them) — see DataBackupService.exportBackup.
    //  3. A crash-loop guard: an attempt marks itself "in progress"
    //     before starting and clears the mark when it ends. If the
    //     process died mid-attempt (the mark is still set next launch),
    //     automatic backup pauses for [_backoffAfterCrash] instead of
    //     retrying — and crashing — on every single launch.
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();

      final skipUntilMillis = prefs.getInt(_skipUntilKey);
      if (skipUntilMillis != null && now.millisecondsSinceEpoch < skipUntilMillis) return;

      if (prefs.getBool(_inProgressKey) ?? false) {
        await prefs.setBool(_inProgressKey, false);
        await prefs.setInt(_skipUntilKey, now.add(_backoffAfterCrash).millisecondsSinceEpoch);
        return;
      }

      await Future<void>.delayed(startDelay);
      if (!await _cloudService.isOnline) return;
      final last = await lastSuccessfulBackupAt();
      if (last != null && DateTime.now().difference(last) < minInterval) return;

      await prefs.setBool(_inProgressKey, true);
      try {
        final zipFile = await _backupService.exportBackup(includeScriptPhotos: false);
        await _cloudService.uploadBackup(zipFile);
        await _cloudService.pruneOldBackups();
        await prefs.setInt(_lastBackupKey, DateTime.now().millisecondsSinceEpoch);
      } finally {
        await prefs.setBool(_inProgressKey, false);
      }
    } catch (_) {
      // Silent, deliberately — see this method's own doc comment.
    }
  }

  /// Called by the manual "Back Up to Cloud" button — same upload/prune
  /// steps, but errors propagate (the button's own screen shows them) and
  /// the last-success timestamp still updates on success, so a manual
  /// backup also resets the automatic schedule rather than the two paths
  /// tracking separate clocks.
  Future<void> backUpNowToCloud() async {
    final zipFile = await _backupService.exportBackup();
    await _cloudService.uploadBackup(zipFile);
    await _cloudService.pruneOldBackups();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastBackupKey, DateTime.now().millisecondsSinceEpoch);
  }
}
