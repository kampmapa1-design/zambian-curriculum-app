import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/subject_content_item.dart';
import 'subject_content_extraction_service.dart';

/// The app's on-device "Subject Content Database" — a physical local store
/// of downloaded CDC materials (Teaching Modules, syllabi, etc.), organized
/// by subject, that the app can draw on as a reserve for lesson-plan,
/// teaching-notes, and slide generation without needing a fresh download
/// each time. Deliberately kept lean: every item is stored as its
/// extracted plain text (see [SubjectContentExtractionService]), not the
/// original PDF — a Teaching Module's real curriculum content runs a few
/// tens of KB as text against a PDF often 1-10+MB. Real people's names in
/// a module's front matter (authors, coordinators) are stripped during
/// extraction and never stored — see subjectContent.ts server-side for
/// exactly how.
class SubjectContentRepository {
  SubjectContentRepository({SubjectContentExtractionService? extractionService})
      : _extractionService = extractionService ?? SubjectContentExtractionService();

  final SubjectContentExtractionService _extractionService;

  static const _catalogFileName = 'subject_content_catalog.json';
  static const _contentDirName = 'subject_content';

  Future<Directory> _rootDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final contentDir = Directory(p.join(dir.path, _contentDirName));
    if (!await contentDir.exists()) await contentDir.create(recursive: true);
    return contentDir;
  }

  Future<File> _catalogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _catalogFileName));
  }

  /// Loads the catalog, first making sure every bundled material (see
  /// [_seedBundledContent] — real Teaching Module content shipped inside
  /// the app itself, e.g. assets/subject_content/civic_education/...) is
  /// already in it. This is how a teacher gets working Subject Content
  /// Database material from the moment they install the app, with no
  /// download, no file picker, no "which subject is this" prompt — the
  /// manual import in Settings still exists for material beyond what's
  /// bundled, but nothing required depends on a teacher finding it.
  Future<SubjectContentCatalog> loadCatalog() async {
    await _seedBundledContent();
    return _loadCatalogRaw();
  }

  Future<SubjectContentCatalog> _loadCatalogRaw() async {
    final file = await _catalogFile();
    if (!await file.exists()) return SubjectContentCatalog.empty();
    try {
      return SubjectContentCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return SubjectContentCatalog.empty();
    }
  }

  /// Copies any not-yet-present bundled manifest entry into the same
  /// on-device storage a downloaded or imported item uses — a one-time,
  /// idempotent operation per item (checked by its stable `bundled://...`
  /// sourceUrl), cheap enough to run on every [loadCatalog] call. Shipping
  /// a new bundled item in a future app update means existing installs
  /// pick it up automatically the next time anything loads the catalog,
  /// with no migration step needed.
  Future<void> _seedBundledContent() async {
    List<dynamic> manifestItems;
    try {
      final raw = await rootBundle.loadString('assets/subject_content/manifest.json');
      manifestItems = (jsonDecode(raw) as Map<String, dynamic>)['items'] as List<dynamic>;
    } catch (error) {
      debugPrint('SubjectContentRepository: no bundled subject_content manifest found ($error)');
      return;
    }
    if (manifestItems.isEmpty) return;

    final catalog = await _loadCatalogRaw();
    final existingUrls = catalog.items.map((i) => i.sourceUrl).toSet();
    final toAdd = manifestItems.cast<Map<String, dynamic>>().where((m) => !existingUrls.contains(m['sourceUrl']));
    if (toAdd.isEmpty) return;

    final updated = [...catalog.items];
    for (final m in toAdd) {
      try {
        final assetPath = 'assets/subject_content/${m['fileName']}';
        final text = await rootBundle.loadString(assetPath);

        final subjectName = m['subjectName'] as String;
        final subjectDir = Directory(p.join((await _rootDir()).path, _slug(subjectName)));
        if (!await subjectDir.exists()) await subjectDir.create(recursive: true);
        final storedFileName = '${_slug(m['title'] as String)}.txt';
        final file = File(p.join(subjectDir.path, storedFileName));
        await file.writeAsString(text, flush: true);

        updated.add(SubjectContentItem(
          title: m['title'] as String,
          subjectName: subjectName,
          resourceType: m['resourceType'] as String,
          sourceUrl: m['sourceUrl'] as String,
          fileName: p.join(_slug(subjectName), storedFileName),
          downloadedAt: DateTime.now(),
          sizeBytes: utf8.encode(text).length,
        ));
      } catch (error) {
        debugPrint('SubjectContentRepository: failed to seed bundled item ${m['title']}: $error');
      }
    }
    await _saveCatalog(SubjectContentCatalog(items: updated));
  }

  Future<void> _saveCatalog(SubjectContentCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  String _slug(String input) {
    final safe = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'item' : safe;
  }

  /// True if a resource (matched by source URL) is already stored.
  Future<bool> containsUrl(String sourceUrl) async {
    final catalog = await loadCatalog();
    return catalog.items.any((i) => i.sourceUrl == sourceUrl);
  }

  /// Saves a material into the database under [subjectName], extracting
  /// its real teaching-content text so it's stored lean and is usable
  /// offline forever after (only the extraction step itself needs a live
  /// connection). If extraction fails right now (offline, or a transient
  /// function error), the original PDF is kept instead, marked
  /// [SubjectContentItem.isLegacyPdf] — nothing is lost, and
  /// [migrateLegacyItems] converts it the next time the app is online.
  Future<SubjectContentItem> store({
    required String title,
    required String subjectName,
    required String resourceType,
    required String sourceUrl,
    required List<int> bytes,
  }) async {
    final safeSubject = subjectName.trim().isNotEmpty ? subjectName.trim() : 'Unspecified';
    final subjectDir = Directory(p.join((await _rootDir()).path, _slug(safeSubject)));
    if (!await subjectDir.exists()) await subjectDir.create(recursive: true);

    final baseName = _slug(title);
    String fileName;
    List<int> contentToStore;
    bool isLegacyPdf;
    try {
      final text = await _extractionService.extractText(bytes);
      fileName = '$baseName.txt';
      contentToStore = utf8.encode(text);
      isLegacyPdf = false;
    } on SubjectContentExtractionUnavailable catch (e) {
      debugPrint('SubjectContentRepository: extraction unavailable ($e), storing raw PDF for later migration');
      fileName = '$baseName.pdf';
      contentToStore = bytes;
      isLegacyPdf = true;
    }

    final file = File(p.join(subjectDir.path, fileName));
    await file.writeAsBytes(contentToStore, flush: true);

    final item = SubjectContentItem(
      title: title,
      subjectName: safeSubject,
      resourceType: resourceType,
      sourceUrl: sourceUrl,
      fileName: p.join(_slug(safeSubject), fileName),
      downloadedAt: DateTime.now(),
      sizeBytes: contentToStore.length,
      isLegacyPdf: isLegacyPdf,
    );

    final catalog = await loadCatalog();
    final byUrl = {for (final i in catalog.items) i.sourceUrl: i};
    // A previous copy of this same resource might be stored under a
    // different filename (e.g. converting from .pdf to .txt) — remove its
    // file too so migration/re-import doesn't leave an orphaned copy.
    final previous = byUrl[item.sourceUrl];
    if (previous != null && previous.fileName != item.fileName) {
      final root = await getApplicationDocumentsDirectory();
      final oldFile = File(p.join(root.path, _contentDirName, previous.fileName));
      if (await oldFile.exists()) await oldFile.delete();
    }
    byUrl[item.sourceUrl] = item;
    await _saveCatalog(SubjectContentCatalog(items: byUrl.values.toList()));
    return item;
  }

  /// Re-runs extraction for every item still stored as a raw PDF (saved
  /// before text extraction existed, or saved while offline) — converts
  /// each to the lean text format in place. Call opportunistically
  /// whenever the app is online (e.g. opening Settings); silently does
  /// nothing if there's nothing to migrate or the app is offline.
  /// Returns how many items were converted.
  Future<int> migrateLegacyItems() async {
    final catalog = await loadCatalog();
    final legacy = catalog.items.where((i) => i.isLegacyPdf).toList();
    if (legacy.isEmpty) return 0;
    if (!await _extractionService.isOnline) return 0;

    var converted = 0;
    for (final item in legacy) {
      try {
        final oldFile = await fileFor(item);
        if (!await oldFile.exists()) continue;
        final bytes = await oldFile.readAsBytes();
        await store(
          title: item.title,
          subjectName: item.subjectName,
          resourceType: item.resourceType,
          sourceUrl: item.sourceUrl,
          bytes: bytes,
        );
        converted++;
      } catch (e) {
        debugPrint('SubjectContentRepository: migration failed for ${item.title}: $e');
        // Leave this one as-is — it'll be retried next time.
      }
    }
    return converted;
  }

  /// Deletes [item]'s file and its catalog entry.
  Future<void> remove(SubjectContentItem item) async {
    final root = await getApplicationDocumentsDirectory();
    final file = File(p.join(root.path, _contentDirName, item.fileName));
    if (await file.exists()) await file.delete();

    final catalog = await loadCatalog();
    await _saveCatalog(SubjectContentCatalog(items: catalog.items.where((i) => i.sourceUrl != item.sourceUrl).toList()));
  }

  /// The full local path to a stored item's file — for opening/sharing it.
  Future<File> fileFor(SubjectContentItem item) async {
    final root = await getApplicationDocumentsDirectory();
    return File(p.join(root.path, _contentDirName, item.fileName));
  }

  /// The stored plain text for [item], or null for a not-yet-migrated
  /// legacy PDF item (nothing to read as text yet).
  Future<String?> readText(SubjectContentItem item) async {
    if (item.isLegacyPdf) return null;
    final file = await fileFor(item);
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// Finds the best-matching real-content excerpt for a lesson topic —
  /// entirely offline, no AI: scores each stored item's text by how many
  /// distinct topic/sub-topic keywords appear in each paragraph, and
  /// returns the highest-scoring paragraph(s) (up to ~350 words) from the
  /// best-matching item. [subjectName] narrows the search to just that
  /// subject's materials when the caller knows it; omit it to search
  /// everything stored (the keyword-overlap scoring already makes an
  /// irrelevant cross-subject match unlikely). Returns null when nothing
  /// stored actually mentions the topic — callers should treat that as
  /// "no enrichment available", not an error, and fall back to their
  /// existing syllabus-only content exactly as before this existed.
  Future<String?> findRelevantExcerpt({
    String? subjectName,
    required String topicName,
    String? subTopicName,
  }) async {
    final catalog = await loadCatalog();
    final candidates = catalog.items.where(
      (i) => !i.isLegacyPdf && (subjectName == null || i.subjectName.toLowerCase() == subjectName.toLowerCase()),
    );
    if (candidates.isEmpty) return null;

    final keywords = _keywordsOf('$topicName ${subTopicName ?? ''}');
    if (keywords.isEmpty) return null;

    String? bestExcerpt;
    var bestScore = 0;

    for (final item in candidates) {
      final text = await readText(item);
      if (text == null || text.isEmpty) continue;

      final paragraphs = text.split(RegExp(r'\n\s*\n')).where((p) => p.trim().length > 40).toList();
      for (var i = 0; i < paragraphs.length; i++) {
        final paragraph = paragraphs[i].trim();
        final paragraphWords = _keywordsOf(paragraph);
        final score = keywords.where(paragraphWords.contains).length;
        if (score > bestScore) {
          bestScore = score;
          // Include the next paragraph too when it's short (often a
          // continuation/example) — capped so this stays an excerpt, not
          // a dump of the whole module.
          final extended = (i + 1 < paragraphs.length && paragraphs[i + 1].trim().length < 300)
              ? '$paragraph\n\n${paragraphs[i + 1].trim()}'
              : paragraph;
          bestExcerpt = _capExcerptWords(extended, 350);
        }
      }
    }

    return bestScore > 0 ? bestExcerpt : null;
  }

  Set<String> _keywordsOf(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 3)
      .toSet();

  String _capExcerptWords(String text, int maxWords) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length <= maxWords) return text.trim();
    return '${words.take(maxWords).join(' ')}...';
  }
}
