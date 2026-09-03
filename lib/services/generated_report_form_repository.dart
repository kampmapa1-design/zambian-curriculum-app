import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/generated_report_form.dart';

/// On-device storage for generated report form Word documents — Stage 10
/// onward. Same dual-retention pattern as [MarkingScriptRepository]/
/// [AssignmentSubmissionRepository]: one small JSON catalog for metadata,
/// one content directory holding the actual .docx files. Fully offline —
/// generating and storing a report never needs a connection; only
/// transmission (Stage 15) does.
class GeneratedReportFormRepository {
  static const _catalogFileName = 'generated_report_forms_catalog.json';
  static const _contentDirName = 'generated_report_forms';

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

  Future<GeneratedReportFormCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return GeneratedReportFormCatalog.empty();
    try {
      return GeneratedReportFormCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return GeneratedReportFormCatalog.empty();
    }
  }

  Future<void> _saveCatalog(GeneratedReportFormCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  String _slug(String input) {
    final safe = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return safe.isEmpty ? 'report' : safe;
  }

  Future<List<GeneratedReportForm>> listForClass(int classId) async {
    final catalog = await loadCatalog();
    return catalog.reports.where((r) => r.classId == classId).toList()
      ..sort((a, b) => a.learnerName.compareTo(b.learnerName));
  }

  /// Writes [docxBytes] to this report's own permanent file and records it
  /// in the catalog, replacing any earlier report already on file for this
  /// exact learner+class (a re-generation of the same learner's report,
  /// e.g. after a score correction, replaces rather than duplicates).
  Future<GeneratedReportForm> saveReport({
    required int classId,
    required int learnerId,
    required String learnerName,
    required List<int> docxBytes,
  }) async {
    final catalog = await loadCatalog();
    final existing = catalog.reports.where((r) => r.classId == classId && r.learnerId == learnerId).firstOrNull;
    final id = existing?.id ?? '${DateTime.now().millisecondsSinceEpoch}_${_slug(learnerName)}';
    final fileName = '$id.docx';
    final file = File(p.join((await _rootDir()).path, fileName));
    await file.writeAsBytes(docxBytes, flush: true);

    final report = GeneratedReportForm(
      id: id,
      classId: classId,
      learnerId: learnerId,
      learnerName: learnerName,
      docFileName: fileName,
      generatedAt: DateTime.now(),
      submissionHash: sha256.convert(docxBytes).toString(),
      // A fresh generation always resets signed status - re-generating
      // (e.g. after fixing a score) must not leave a stale "signed" badge
      // on content the Head Teacher never actually approved.
    );

    final withoutOld = catalog.reports.where((r) => r.id != id).toList();
    await _saveCatalog(GeneratedReportFormCatalog(reports: [...withoutOld, report]));
    return report;
  }

  Future<File> fileFor(GeneratedReportForm report) async {
    final root = await _rootDir();
    return File(p.join(root.path, report.docFileName));
  }

  /// Stage 12 — replaces one report's file with a re-generated version
  /// that has the Head Teacher's signature embedded, and marks it signed.
  /// Called once per report in the approved batch, never for the whole
  /// class at once without each one's own document actually being
  /// re-rendered with the signature — see ReportFormDocumentService.
  Future<GeneratedReportForm> markSigned({
    required GeneratedReportForm report,
    required List<int> signedDocxBytes,
    required String signedByName,
  }) async {
    final file = await fileFor(report);
    await file.writeAsBytes(signedDocxBytes, flush: true);

    final updated = report.copyWith(
      submissionHash: sha256.convert(signedDocxBytes).toString(),
      signed: true,
      signedAt: DateTime.now(),
      signedByName: signedByName,
    );
    final catalog = await loadCatalog();
    await _saveCatalog(GeneratedReportFormCatalog(
      reports: [for (final r in catalog.reports) if (r.id == report.id) updated else r],
    ));
    return updated;
  }
}
