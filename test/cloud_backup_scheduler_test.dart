import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zambian_curriculum_app/services/cloud_backup_scheduler.dart';
import 'package:zambian_curriculum_app/services/cloud_backup_service.dart';
import 'package:zambian_curriculum_app/services/data_backup_service.dart';

/// Regression coverage for [CloudBackupScheduler]'s own core logic — the
/// "is it time for another automatic backup yet" gate, and that a
/// completed backup (automatic or manual) actually advances the clock, is
/// exactly the kind of off-by-one/never-fires-again bug that's easy to get
/// wrong and easy to miss by eye (same reasoning as this repo's other
/// service-level tests, e.g. FreeTierEntitlementService's own).
///
/// Both fakes override every method [CloudBackupScheduler] actually calls,
/// so neither ever touches a real Firebase/Storage object — no Firebase
/// app needs to exist for this test (same technique used in
/// batch_grading_runner_retry_test.dart).
class _FakeDataBackupService implements DataBackupService {
  int exportCount = 0;
  bool? lastIncludeScriptPhotos;

  @override
  Future<File> exportBackup({bool includeScriptPhotos = true}) async {
    exportCount++;
    lastIncludeScriptPhotos = includeScriptPhotos;
    return File('fake_backup.zip');
  }

  @override
  Future<BackupManifest> readManifest(File zipFile) => throw UnimplementedError();
  @override
  Future<void> importBackup(File zipFile) => throw UnimplementedError();
}

class _FakeCloudBackupService implements CloudBackupService {
  _FakeCloudBackupService({this.online = true, this.uploadShouldThrow = false});

  final bool online;
  final bool uploadShouldThrow;
  int uploadCount = 0;
  int pruneCount = 0;

  @override
  Future<bool> get isOnline async => online;

  @override
  Future<void> uploadBackup(File zipFile) async {
    if (uploadShouldThrow) throw const CloudBackupUnavailable('simulated upload failure');
    uploadCount++;
  }

  @override
  Future<void> pruneOldBackups({int keep = 14}) async {
    pruneCount++;
  }

  @override
  Future<List<CloudBackupEntry>> listBackups() => throw UnimplementedError();
  @override
  Future<File> downloadBackup(CloudBackupEntry entry) => throw UnimplementedError();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('maybeBackUpInBackground', () {
    test('backs up immediately when no backup has ever succeeded before', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService();
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);

      expect(dataService.exportCount, 1);
      expect(cloudService.uploadCount, 1);
      expect(cloudService.pruneCount, 1);
      expect(await scheduler.lastSuccessfulBackupAt(), isNotNull);
    });

    test('does nothing when offline, even if a backup is overdue', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService(online: false);
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);

      expect(dataService.exportCount, 0);
      expect(cloudService.uploadCount, 0);
      expect(await scheduler.lastSuccessfulBackupAt(), isNull);
    });

    test('skips a second backup within minInterval of a successful one', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService();
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await scheduler.maybeBackUpInBackground(minInterval: const Duration(days: 1), startDelay: Duration.zero);
      expect(dataService.exportCount, 1);

      // Called again immediately — well within the 1-day interval.
      await scheduler.maybeBackUpInBackground(minInterval: const Duration(days: 1), startDelay: Duration.zero);
      expect(dataService.exportCount, 1, reason: 'a second call inside minInterval must not trigger another export');
    });

    test('backs up again once minInterval has genuinely elapsed', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService();
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      // Seed "last backup" as already outside a zero-length interval —
      // any real elapsed time satisfies Duration.zero, so this exercises
      // the "interval has elapsed" branch without a real clock wait.
      await scheduler.maybeBackUpInBackground(minInterval: Duration.zero, startDelay: Duration.zero);
      expect(dataService.exportCount, 1);

      await scheduler.maybeBackUpInBackground(minInterval: Duration.zero, startDelay: Duration.zero);
      expect(dataService.exportCount, 2, reason: 'a zero minInterval means every call is due');
    });

    test('a failed upload does not advance the last-success clock', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService(uploadShouldThrow: true);
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);

      expect(dataService.exportCount, 1, reason: 'export still runs before the upload fails');
      expect(await scheduler.lastSuccessfulBackupAt(), isNull, reason: 'a failed upload must not count as a success');
    });

    test('the automatic backup never includes script photos (the manual button still does)', () async {
      final dataService = _FakeDataBackupService();
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: _FakeCloudBackupService());

      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);
      expect(dataService.lastIncludeScriptPhotos, isFalse);

      await scheduler.backUpNowToCloud();
      expect(dataService.lastIncludeScriptPhotos, isTrue);
    });

    test('crash-loop guard: an attempt that never finished pauses automatic backup instead of retrying every launch', () async {
      // Simulates the process having been killed mid-backup last launch:
      // the in-progress mark was set and never cleared.
      SharedPreferences.setMockInitialValues({'cloud_backup_attempt_in_progress': true});
      final dataService = _FakeDataBackupService();
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: _FakeCloudBackupService());

      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);
      expect(dataService.exportCount, 0, reason: 'must not retry the attempt that just killed the app');

      // And the next launches stay paused for the back-off window.
      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);
      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero);
      expect(dataService.exportCount, 0);
    });

    test('a normal attempt clears its in-progress mark, so it does not look like a crash next launch', () async {
      final dataService = _FakeDataBackupService();
      final scheduler = CloudBackupScheduler(
        backupService: dataService,
        cloudService: _FakeCloudBackupService(uploadShouldThrow: true),
      );
      await scheduler.maybeBackUpInBackground(startDelay: Duration.zero); // fails, cleanly
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('cloud_backup_attempt_in_progress'), isFalse);
    });

    test('never throws to its caller, even when everything fails', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService(uploadShouldThrow: true);
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await expectLater(scheduler.maybeBackUpInBackground(startDelay: Duration.zero), completes);
    });
  });

  group('backUpNowToCloud (manual button)', () {
    test('a successful manual backup also advances the automatic schedule\'s clock', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService();
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await scheduler.backUpNowToCloud();
      expect(await scheduler.lastSuccessfulBackupAt(), isNotNull);

      // The automatic path must now see a backup as not-yet-due.
      await scheduler.maybeBackUpInBackground(minInterval: const Duration(days: 1), startDelay: Duration.zero);
      expect(dataService.exportCount, 1, reason: 'the manual backup above already satisfied the daily schedule');
    });

    test('propagates a real error to its caller (unlike the automatic path)', () async {
      final dataService = _FakeDataBackupService();
      final cloudService = _FakeCloudBackupService(uploadShouldThrow: true);
      final scheduler = CloudBackupScheduler(backupService: dataService, cloudService: cloudService);

      await expectLater(scheduler.backUpNowToCloud(), throwsA(isA<CloudBackupUnavailable>()));
    });
  });
}
