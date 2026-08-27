import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/marking_scheme.dart';

/// On-device storage for reusable marking schemes (AI-Assisted Marking,
/// Stage 3) — a single small JSON catalog, fully offline, mirroring the
/// pattern used elsewhere in the app (SubjectContentRepository,
/// MarkingScriptRepository).
class MarkingSchemeRepository {
  static const _catalogFileName = 'marking_schemes_catalog.json';

  Future<File> _catalogFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _catalogFileName));
  }

  Future<MarkingSchemeCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return MarkingSchemeCatalog.empty();
    try {
      return MarkingSchemeCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return MarkingSchemeCatalog.empty();
    }
  }

  Future<void> _saveCatalog(MarkingSchemeCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  Future<MarkingScheme> save(MarkingScheme scheme) async {
    final catalog = await loadCatalog();
    final byId = {for (final s in catalog.schemes) s.id: s};
    byId[scheme.id] = scheme;
    await _saveCatalog(MarkingSchemeCatalog(schemes: byId.values.toList()));
    return scheme;
  }

  Future<void> remove(MarkingScheme scheme) async {
    final catalog = await loadCatalog();
    await _saveCatalog(MarkingSchemeCatalog(schemes: catalog.schemes.where((s) => s.id != scheme.id).toList()));
  }
}
