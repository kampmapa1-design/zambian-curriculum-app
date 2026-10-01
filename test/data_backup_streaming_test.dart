import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zambian_curriculum_app/services/data_backup_service.dart';

import 'support/sqlite_test_setup.dart';

/// Real-file coverage for DataBackupService.exportBackup's streaming rewrite
/// (2026-09-26) — the version that used to hold every script photo in memory
/// twice over on every app open and got the app killed by Android.
void main() {
  late Directory docs;

  setUp(() async {
    await setUpTestDatabase();
    docs = await getApplicationDocumentsDirectory();
    // Clean slate for the files this test owns.
    for (final name in ['marking_scripts', 'marking_scripts_catalog.json']) {
      final f = p.join(docs.path, name);
      if (await Directory(f).exists()) await Directory(f).delete(recursive: true);
      if (await File(f).exists()) await File(f).delete();
    }
    final photoDir = Directory(p.join(docs.path, 'marking_scripts', 's1'))..createSync(recursive: true);
    File(p.join(photoDir.path, 'page1.jpg')).writeAsBytesSync(List.generate(50000, (i) => i % 251));
    File(p.join(photoDir.path, 'page2.jpg')).writeAsBytesSync(List.generate(30000, (i) => i % 241));
    File(p.join(docs.path, 'marking_scripts_catalog.json')).writeAsStringSync(jsonEncode({
      'scripts': [
        {'id': 's1', 'pageFileNames': ['page1.jpg', 'page2.jpg']},
      ],
    }));
  });

  Archive read(File zip) => ZipDecoder().decodeBytes(zip.readAsBytesSync());

  test('with photos: every photo lands in the zip, byte for byte, and the manifest counts them', () async {
    final zip = await DataBackupService().exportBackup();
    final archive = read(zip);

    final photo = archive.findFile('script_photos/s1/page1.jpg');
    expect(photo, isNotNull);
    expect(photo!.content as List<int>, File(p.join(docs.path, 'marking_scripts', 's1', 'page1.jpg')).readAsBytesSync());
    expect(archive.findFile('script_photos/s1/page2.jpg'), isNotNull);

    final manifest = jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content as List<int>)) as Map;
    expect(manifest['includes_script_photos'], isTrue);
    expect(manifest['script_photo_count'], 2);
    expect(manifest['script_photo_bytes'], 80000);
    expect(archive.findFile('sidecars/marking_scripts_catalog.json'), isNotNull);
  });

  test('without photos (the automatic backup): no photo entries, and the manifest says so honestly', () async {
    final zip = await DataBackupService().exportBackup(includeScriptPhotos: false);
    final archive = read(zip);

    expect(archive.files.where((f) => f.name.startsWith('script_photos/')), isEmpty);
    final manifest = jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content as List<int>)) as Map;
    expect(manifest['includes_script_photos'], isFalse);
    expect(manifest['script_photo_count'], 0);
    expect(archive.findFile('sidecars/marking_scripts_catalog.json'), isNotNull, reason: 'the catalog itself is still backed up');
  });

  test('restoring a no-photo backup never deletes the photos already on the device', () async {
    final noPhotos = await DataBackupService().exportBackup(includeScriptPhotos: false);
    final photo = File(p.join(docs.path, 'marking_scripts', 's1', 'page1.jpg'));
    expect(photo.existsSync(), isTrue);

    await DataBackupService().importBackup(noPhotos);

    expect(photo.existsSync(), isTrue, reason: 'a backup without photos must leave local photos alone');
  });

  test('restoring a with-photos backup still fully replaces the photo directory (unchanged behaviour)', () async {
    final withPhotos = await DataBackupService().exportBackup();
    final stray = File(p.join(docs.path, 'marking_scripts', 's1', 'stray.jpg'))..writeAsBytesSync([1, 2, 3]);

    await DataBackupService().importBackup(withPhotos);

    expect(stray.existsSync(), isFalse, reason: 'full-replace restore removes photos that are not in the backup');
    expect(File(p.join(docs.path, 'marking_scripts', 's1', 'page1.jpg')).existsSync(), isTrue);
  });
}
