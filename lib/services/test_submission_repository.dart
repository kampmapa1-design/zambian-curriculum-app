import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/test_submission.dart';

/// On-device storage for Test Submission drafts and finished submissions —
/// identical structure to [AssignmentSubmissionRepository] (a small JSON
/// catalog plus a per-submission subdirectory for its images/PDF/bundle).
/// Nothing here is ever deleted by a successful send — only an explicit
/// [remove] call touches disk.
class TestSubmissionRepository {
  static const _catalogFileName = 'test_submissions_catalog.json';
  static const _contentDirName = 'test_submissions';

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

  Future<TestSubmissionCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return TestSubmissionCatalog.empty();
    try {
      return TestSubmissionCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return TestSubmissionCatalog.empty();
    }
  }

  Future<void> _saveCatalog(TestSubmissionCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  Future<TestSubmission> createDraft() async {
    final submission = TestSubmission(id: '${DateTime.now().millisecondsSinceEpoch}', createdAt: DateTime.now());
    final catalog = await loadCatalog();
    await _saveCatalog(TestSubmissionCatalog(submissions: [...catalog.submissions, submission]));
    return submission;
  }

  Future<Directory> submissionDir(TestSubmission submission) async {
    final dir = Directory(p.join((await _rootDir()).path, submission.id));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> storeFile(TestSubmission submission, File file, String fileName) async {
    final dir = await submissionDir(submission);
    await file.copy(p.join(dir.path, fileName));
    return fileName;
  }

  Future<List<File>> pageFilesFor(TestSubmission submission, List<String> fileNames) async {
    final dir = await submissionDir(submission);
    return [for (final name in fileNames) File(p.join(dir.path, name))];
  }

  File fileFor(TestSubmission submission, Directory dir, String fileName) => File(p.join(dir.path, fileName));

  Future<void> update(TestSubmission submission) async {
    final catalog = await loadCatalog();
    final updated = [for (final s in catalog.submissions) if (s.id == submission.id) submission else s];
    await _saveCatalog(TestSubmissionCatalog(submissions: updated));
  }

  Future<void> remove(TestSubmission submission) async {
    final dir = Directory(p.join((await _rootDir()).path, submission.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    final catalog = await loadCatalog();
    await _saveCatalog(
      TestSubmissionCatalog(submissions: catalog.submissions.where((s) => s.id != submission.id).toList()),
    );
  }
}
