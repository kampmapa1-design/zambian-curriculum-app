import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/sugo_library_note.dart';
import 'auth_service.dart';

/// Sugo Library — Stages 1 and 7 (owner request, 2026-09-29): fetches the
/// shared content-version manifest and individual topic notes from
/// Firestore, caching each downloaded topic on-device so reading it again
/// later needs no network at all. [isTopicDownloaded]/[downloadTopic] are
/// what [Stage 7]'s "Available Offline" / "Tap to Download" badges are
/// driven by. Writing here is owner-only — see `saveSugoLibraryTopic` in
/// index.ts — this service only ever reads.
class SugoLibraryService {
  SugoLibraryService({FirebaseFirestore? firestore}) : _firestore = firestore;

  final FirebaseFirestore? _firestore;
  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  static const _cacheDirName = 'sugo_library';
  static const _bundledAssetPath = 'assets/sugo_library/bundled_content.json';

  static Map<String, SugoLibraryNote>? _bundledCache;

  /// Notes shipped inside the app itself (no Firestore, no network) — a
  /// first slice of real generated content so the Library has something to
  /// read before the shared Firestore bank is populated. Empty on any load
  /// failure so a broken asset can never take the Library down.
  Future<Map<String, SugoLibraryNote>> bundledNotes() async {
    final cached = _bundledCache;
    if (cached != null) return cached;
    try {
      final raw = jsonDecode(await rootBundle.loadString(_bundledAssetPath)) as Map<String, dynamic>;
      return _bundledCache = {
        for (final e in raw.entries) e.key: SugoLibraryNote.fromMap((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return _bundledCache = const {};
    }
  }

  Future<Directory> _cacheDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(dir.path, _cacheDirName));
    if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
    return cacheDir;
  }

  Future<File> _cacheFile(String topicId) async => File(p.join((await _cacheDir()).path, '$topicId.json'));

  /// The shared manifest — every topic's current content-version hash.
  /// Null (not an empty map) when it genuinely can't be reached right now
  /// (offline, or nothing generated yet) — callers should fall back to
  /// whatever's already cached rather than treating this as "nothing
  /// exists".
  Future<Map<String, String>?> fetchManifest() async {
    try {
      await AuthService.instance.ensureSignedIn();
      final doc = await _db.collection('appConfig').doc('sugoLibraryManifest').get();
      final hashes = doc.data()?['hashes'] as Map<String, dynamic>?;
      if (hashes == null) return null;
      return hashes.map((key, value) => MapEntry(key, value as String? ?? ''));
    } catch (_) {
      return null;
    }
  }

  /// Whether [topicId]'s locally cached copy matches [currentVersion] (from
  /// the manifest) — true only when a cached file exists AND its own stored
  /// version matches exactly, so a stale cache never silently passes as
  /// "up to date".
  Future<bool> isTopicDownloaded(String topicId, {String? currentVersion}) async {
    if ((await bundledNotes()).containsKey(topicId)) return true;
    final file = await _cacheFile(topicId);
    if (!await file.exists()) return false;
    if (currentVersion == null) return true;
    try {
      final cached = SugoLibraryNote.fromMap(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      return cached.contentVersion == currentVersion;
    } catch (_) {
      return false;
    }
  }

  /// The cached copy, if any — reads local disk only, no network, so this
  /// is safe to call unconditionally (e.g. to show notes while a fresher
  /// version downloads in the background).
  Future<SugoLibraryNote?> cachedTopic(String topicId) async {
    final file = await _cacheFile(topicId);
    if (await file.exists()) {
      try {
        return SugoLibraryNote.fromMap(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        // fall through to the bundled copy
      }
    }
    return (await bundledNotes())[topicId];
  }

  /// Downloads [topicId] from Firestore and caches it on-device. Returns
  /// the cached copy on failure (offline mid-download) rather than null, so
  /// a caller that already has something to show never loses it just
  /// because a refresh failed.
  Future<SugoLibraryNote?> downloadTopic(String topicId) async {
    try {
      await AuthService.instance.ensureSignedIn();
      final doc = await _db.collection('sugoLibrary').doc(topicId).get();
      final data = doc.data();
      if (data == null) return await cachedTopic(topicId);
      final note = SugoLibraryNote.fromMap(data);
      final file = await _cacheFile(topicId);
      await file.writeAsString(jsonEncode(note.toMap()), flush: true);
      return note;
    } catch (_) {
      return cachedTopic(topicId);
    }
  }

  /// Fetch-then-cache in one call, used by the notes screen: returns the
  /// cache immediately if it's already current per [manifestVersion] (no
  /// network), else downloads and caches the fresh copy. Pass a null
  /// [manifestVersion] (manifest unreachable) to just prefer whatever's
  /// cached, falling back to a download only if nothing is cached at all.
  Future<SugoLibraryNote?> ensureTopic(String topicId, {String? manifestVersion}) async {
    final bundled = (await bundledNotes())[topicId];
    if (bundled != null && manifestVersion == null) return cachedTopic(topicId);
    if (manifestVersion != null && await isTopicDownloaded(topicId, currentVersion: manifestVersion)) {
      return cachedTopic(topicId);
    }
    final cached = await cachedTopic(topicId);
    if (cached != null && manifestVersion == null) return cached;
    return downloadTopic(topicId);
  }
}
