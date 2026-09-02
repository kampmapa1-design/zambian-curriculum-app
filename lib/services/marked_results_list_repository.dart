import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/marked_results_list.dart';

/// On-device storage for [MarkedResultsList]s (Chief Marker, added
/// 2026-09-02) — same small-JSON-catalog house pattern as
/// MarkingScriptRepository/AssignmentSubmissionRepository, no per-list
/// subdirectory needed since a list only ever stores script IDs, not
/// files of its own (the scripts themselves stay wherever
/// MarkingScriptRepository already keeps them).
class MarkedResultsListRepository {
  static const _catalogFileName = 'marked_results_lists_catalog.json';

  Future<File> _catalogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _catalogFileName));
  }

  Future<MarkedResultsListCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return MarkedResultsListCatalog.empty();
    try {
      return MarkedResultsListCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return MarkedResultsListCatalog.empty();
    }
  }

  Future<void> _saveCatalog(MarkedResultsListCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  Future<MarkedResultsList> create({required String name, required List<String> scriptIds}) async {
    final list = MarkedResultsList(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      createdAt: DateTime.now(),
      scriptIds: scriptIds,
    );
    final catalog = await loadCatalog();
    await _saveCatalog(MarkedResultsListCatalog(lists: [...catalog.lists, list]));
    return list;
  }

  Future<void> update(MarkedResultsList list) async {
    final catalog = await loadCatalog();
    final updated = [for (final l in catalog.lists) if (l.id == list.id) list else l];
    await _saveCatalog(MarkedResultsListCatalog(lists: updated));
  }

  Future<void> remove(MarkedResultsList list) async {
    final catalog = await loadCatalog();
    await _saveCatalog(MarkedResultsListCatalog(lists: catalog.lists.where((l) => l.id != list.id).toList()));
  }
}
