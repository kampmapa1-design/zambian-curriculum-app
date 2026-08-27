import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cdc_resource.dart';
import 'auth_service.dart';

class CdcResourcesUnavailable implements Exception {
  final String message;
  const CdcResourcesUnavailable(this.message);
  @override
  String toString() => message;
}

/// Catalogs CDC Digital Library resources (Teaching Modules, syllabi, etc.)
/// for on-demand download, rather than bundling every PDF in the app —
/// the full library runs into hundreds of megabytes. The catalog itself is
/// cached locally so it's browsable offline; refreshing the catalog and
/// downloading an actual file both require a live connection.
///
/// [refreshIfDue] throttles live catalog fetches to at most once every 7
/// days by default, called opportunistically whenever the app is online
/// (e.g. on opening the CDC Resources screen) rather than needing a true
/// OS-level background job.
class CdcResourcesService {
  CdcResourcesService({FirebaseFunctions? functions, http.Client? httpClient})
      : _functions = functions ?? FirebaseFunctions.instance,
        _httpClient = httpClient ?? http.Client();

  final FirebaseFunctions _functions;
  final http.Client _httpClient;

  static const _cacheFileName = 'cdc_resources_cache.json';
  static const _lastCheckedKey = 'cdc_resources_last_checked_at';
  static const refreshInterval = Duration(days: 7);

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _cacheFileName));
  }

  /// The last successfully cached catalog. On first-ever launch (no cache
  /// file yet), seeds from a bundled snapshot fetched directly from the CDC
  /// Digital Library (assets/cdc_resources/seed_catalog.json — see its
  /// `_source` field) rather than starting empty, so the catalog is useful
  /// offline even before the paid `listCdcResources` refresh is available.
  /// A live refresh later merges into this rather than replacing it.
  Future<CdcCatalog> loadCached() async {
    final file = await _cacheFile();
    if (!await file.exists()) {
      final seeded = await _loadBundledSeed();
      if (seeded != null) await _saveCache(seeded);
      return seeded ?? CdcCatalog.empty();
    }
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return CdcCatalog.fromJson(json);
    } catch (error) {
      // A corrupt cache file shouldn't be a dead end — fall back to the
      // bundled seed rather than an empty catalog. debugPrint (not a
      // silent catch) so a real bug here shows up in `flutter logs`
      // instead of just reading as "no resources catalogued yet".
      debugPrint('CdcResourcesService: cache file was unreadable ($error), falling back to bundled seed');
      return await _loadBundledSeed() ?? CdcCatalog.empty();
    }
  }

  Future<CdcCatalog?> _loadBundledSeed() async {
    try {
      final raw = await rootBundle.loadString('assets/cdc_resources/seed_catalog.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return CdcCatalog.fromJson({'resources': json['resources'], 'fetchedAt': json['fetchedAt']});
    } catch (error, stackTrace) {
      debugPrint('CdcResourcesService: failed to load bundled seed catalog: $error\n$stackTrace');
      return null;
    }
  }

  Future<void> _saveCache(CdcCatalog catalog) async {
    final file = await _cacheFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  Future<DateTime?> get lastCheckedAt async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastCheckedKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<bool> get _dueForCheck async {
    final last = await lastCheckedAt;
    if (last == null) return true;
    return DateTime.now().difference(last) >= refreshInterval;
  }

  /// Refreshes the catalog from the `listCdcResources` Cloud Function if
  /// online and due (see [refreshInterval]), or always if [force] is true.
  /// Newly found resources are merged into the existing cache by URL rather
  /// than replacing it, so a partial crawl on one call still accumulates a
  /// fuller catalog over successive weekly refreshes. Returns null if the
  /// refresh was skipped (offline, or not due yet and not forced) — that is
  /// not an error, just "nothing new to report right now".
  Future<CdcCatalog?> refreshIfDue({bool force = false}) async {
    if (!force && !await _dueForCheck) return null;
    if (!await isOnline) return null;

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable('listCdcResources');
    Map<Object?, Object?> data;
    try {
      final result = await callable.call<Map<Object?, Object?>>();
      data = result.data;
    } on FirebaseFunctionsException catch (e) {
      // 'not-found'/'internal' here almost always means the function hasn't
      // been deployed yet — most likely because the Firebase project is
      // still on the free Spark plan (Cloud Functions can't make outbound
      // calls, like the one this function needs, until Blaze is enabled).
      // Distinguish that from a real network/server error so the message
      // doesn't read like something is broken.
      if (e.code == 'not-found' || e.code == 'internal' || e.code == 'unavailable') {
        throw const CdcResourcesUnavailable(
          'Live catalog updates need the paid Firebase plan, which isn\'t enabled yet — '
          'postponed for now. Downloading individual resources will work once it is.',
        );
      }
      throw CdcResourcesUnavailable(e.message ?? 'Failed to fetch the CDC catalog.');
    }

    final fetched = (data['resources'] as List)
        .cast<Map<Object?, Object?>>()
        .map((m) => CdcResource.fromJson(Map<String, dynamic>.from(m)))
        .toList();

    final existing = await loadCached();
    final byUrl = {for (final r in existing.resources) r.url: r};
    for (final r in fetched) {
      byUrl[r.url] = r;
    }
    final merged = CdcCatalog(resources: byUrl.values.toList(), fetchedAt: DateTime.now());
    await _saveCache(merged);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastCheckedKey, DateTime.now().toIso8601String());

    return merged;
  }

  /// Every resource in this app is a PDF (the download always writes a
  /// `.pdf` file below), so a genuine download starts with the PDF magic
  /// bytes. Anything else — an HTML rate-limit notice, a Drive virus-scan
  /// interstitial, a login page — fails this check instead of silently
  /// being saved as if it were the real file.
  bool _looksLikeRealFile(List<int> bytes) {
    if (bytes.length < 5) return false;
    return bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46 && // F
        bytes[4] == 0x2D; // -
  }

  /// The CDC Digital Library's `resource.php?id=...` pages need `?download=1`
  /// appended to serve the raw file instead of the landing page. Resources
  /// from elsewhere (e.g. syllabi/past papers sourced from other open sites,
  /// already recorded as direct-download URLs — see the `listCdcResources`
  /// prompt) are used as-is, since that CDC-specific query trick doesn't
  /// apply to other hosts.
  String _downloadUrlFor(String resourcePageUrl) {
    final uri = Uri.parse(resourcePageUrl);
    if (uri.host != 'library.cdcrepository.info') return resourcePageUrl;
    return uri.replace(queryParameters: {...uri.queryParameters, 'download': '1'}).toString();
  }

  /// Downloads one resource's actual file to local storage. Requires a live
  /// connection — the catalog can be browsed offline, but files are never
  /// bundled with the app.
  ///
  /// Past papers specifically are routed through the `cleanPastPaperDownload`
  /// Cloud Function rather than fetched directly: redistribution sites
  /// (zedpastpapers.com etc.) stamp a branding watermark onto every page,
  /// and that function strips it server-side before the file ever reaches
  /// the device (see firebase/functions/src/watermark.ts for exactly how —
  /// it targets only the known watermark, real exam content is never
  /// touched). Modules and syllabi come straight from the CDC's own site
  /// and carry no such watermark, so they skip this and download directly.
  Future<File> downloadResource(CdcResource resource) async {
    if (!await isOnline) {
      throw const CdcResourcesUnavailable("You're offline. Connect to the internet to download this file.");
    }

    final List<int> bytes = resource.resourceType == 'past_paper'
        ? await _downloadAndCleanPastPaper(resource)
        : await _downloadDirect(resource);

    final dir = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory(p.join(dir.path, 'cdc_downloads'));
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    final safeName = resource.title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final file = File(p.join(downloadsDir.path, '${safeName.isEmpty ? 'resource' : safeName}.pdf'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<List<int>> _downloadDirect(CdcResource resource) async {
    final response = await _httpClient.get(
      Uri.parse(_downloadUrlFor(resource.url)),
      // Drive occasionally serves an HTML "too many people have
      // viewed/downloaded this file" or virus-scan interstitial with a 200
      // status instead of the real file, especially once a shared file
      // gets popular. A plain UA made this more likely in testing; a
      // browser-like one reduces it, though the PDF-signature check below
      // is what actually catches it either way.
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/128.0.0.0 Safari/537.36',
      },
    );
    if (response.statusCode != 200) {
      throw CdcResourcesUnavailable('Download failed (HTTP ${response.statusCode}).');
    }
    if (!_looksLikeRealFile(response.bodyBytes)) {
      throw const CdcResourcesUnavailable(
        "This file couldn't be downloaded right now — the source may be rate-limiting "
        'downloads. Please try again in a few minutes.',
      );
    }
    return response.bodyBytes;
  }

  Future<List<int>> _downloadAndCleanPastPaper(CdcResource resource) async {
    await AuthService.instance.ensureSignedIn();
    final callable = _functions.httpsCallable(
      'cleanPastPaperDownload',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 90)),
    );
    try {
      final result = await callable.call<Map<Object?, Object?>>({'url': resource.url});
      final base64 = result.data['base64'] as String?;
      if (base64 == null || base64.isEmpty) {
        throw const CdcResourcesUnavailable('The downloaded file was empty. Please try again.');
      }
      final bytes = base64Decode(base64);
      if (!_looksLikeRealFile(bytes)) {
        throw const CdcResourcesUnavailable(
          "This file couldn't be downloaded right now — the source may be rate-limiting "
          'downloads. Please try again in a few minutes.',
        );
      }
      return bytes;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found' || e.code == 'internal' || e.code == 'unavailable') {
        // The cleaning function isn't reachable (not deployed yet, or a
        // transient outage) — fall back to a direct download rather than
        // leaving the teacher with nothing. It just won't have the
        // watermark stripped this one time.
        debugPrint('CdcResourcesService: cleanPastPaperDownload unavailable ($e), falling back to direct download');
        return _downloadDirect(resource);
      }
      throw CdcResourcesUnavailable(e.message ?? 'Failed to download this past paper.');
    }
  }
}
