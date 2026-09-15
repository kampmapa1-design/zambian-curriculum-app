// Shared plumbing for every repository test that touches DatabaseHelper.
// Two real problems to solve here, neither optional under `flutter test`:
//
// 1. DatabaseHelper._open() calls path_provider's
//    getApplicationDocumentsDirectory(), which needs a real platform
//    channel — none exists under `flutter test`. Fixed by swapping in a
//    fake PathProviderPlatform that just returns a real temp directory.
// 2. DatabaseHelper._open() then calls sqflite's plain openDatabase(),
//    which also needs a real platform channel. Fixed by pointing sqflite's
//    global `databaseFactory` at sqflite_common_ffi's FFI-backed one
//    (a real SQLite engine, no platform channel needed) before the first
//    call to DatabaseHelper.instance.database.
//
// DatabaseHelper's own constructor is private (DatabaseHelper._internal())
// — instance is a true process-wide singleton, so a second independent
// instance can't be constructed for test isolation. Instead, every test
// calls [setUpTestDatabase] in its own `setUp`, which wipes every table
// (FK checks off for the wipe, so table order doesn't matter) rather than
// reopening a new database — cheap, and immune to the app's own schema
// evolving without this file needing to track table drop order by hand.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zambian_curriculum_app/services/database_helper.dart';

class _FakePathProviderPlatform extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

bool _wired = false;

/// Call from `setUp` in every test file that exercises a repository backed
/// by DatabaseHelper. Idempotent to call repeatedly across tests.
Future<void> setUpTestDatabase() async {
  if (!_wired) {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = Directory.systemTemp.createTempSync('smart_teacher_test_db_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(dir.path);
    _wired = true;
  }
  await _clearAllTables();
}

Future<void> _clearAllTables() async {
  final db = await DatabaseHelper.instance.database;
  await db.execute('PRAGMA foreign_keys = OFF');
  final tables = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'android_metadata'",
  );
  for (final row in tables) {
    await db.delete(row['name'] as String);
  }
  await db.execute('PRAGMA foreign_keys = ON');
}
