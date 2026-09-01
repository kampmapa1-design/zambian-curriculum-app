import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/assignment_submission.dart';

/// On-device storage for Assignment Submission drafts and finished
/// submissions — mirrors [MarkingScriptRepository]'s pattern (a small JSON
/// catalog plus a per-submission subdirectory for its images/PDF/bundle).
/// Stage 7's "permanent, independent of transmission" requirement is just
/// this: nothing here is ever deleted by a successful send — only an
/// explicit [remove] call (a student choosing to discard a draft) touches
/// disk.
class AssignmentSubmissionRepository {
  static const _catalogFileName = 'assignment_submissions_catalog.json';
  static const _contentDirName = 'assignment_submissions';

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

  Future<AssignmentSubmissionCatalog> loadCatalog() async {
    final file = await _catalogFile();
    if (!await file.exists()) return AssignmentSubmissionCatalog.empty();
    try {
      return AssignmentSubmissionCatalog.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return AssignmentSubmissionCatalog.empty();
    }
  }

  Future<void> _saveCatalog(AssignmentSubmissionCatalog catalog) async {
    final file = await _catalogFile();
    await file.writeAsString(jsonEncode(catalog.toJson()));
  }

  /// Starts a new, empty draft and persists it immediately — every later
  /// stage just updates this same record, so a captured page is never
  /// lost to an app close mid-flow.
  Future<AssignmentSubmission> createDraft() async {
    final submission = AssignmentSubmission(id: '${DateTime.now().millisecondsSinceEpoch}', createdAt: DateTime.now());
    final catalog = await loadCatalog();
    await _saveCatalog(AssignmentSubmissionCatalog(submissions: [...catalog.submissions, submission]));
    return submission;
  }

  Future<Directory> submissionDir(AssignmentSubmission submission) async {
    final dir = Directory(p.join((await _rootDir()).path, submission.id));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copies [file] into this submission's own storage under [fileName],
  /// returning the name to store on the model (never a full path — same
  /// convention as [MarkingScript.pageFileNames], so storage can survive
  /// an app reinstall's documents-directory path changing).
  Future<String> storeFile(AssignmentSubmission submission, File file, String fileName) async {
    final dir = await submissionDir(submission);
    await file.copy(p.join(dir.path, fileName));
    return fileName;
  }

  Future<List<File>> pageFilesFor(AssignmentSubmission submission, List<String> fileNames) async {
    final dir = await submissionDir(submission);
    return [for (final name in fileNames) File(p.join(dir.path, name))];
  }

  File fileFor(AssignmentSubmission submission, Directory dir, String fileName) => File(p.join(dir.path, fileName));

  Future<void> update(AssignmentSubmission submission) async {
    final catalog = await loadCatalog();
    final updated = [for (final s in catalog.submissions) if (s.id == submission.id) submission else s];
    await _saveCatalog(AssignmentSubmissionCatalog(submissions: updated));
  }

  Future<void> remove(AssignmentSubmission submission) async {
    final dir = Directory(p.join((await _rootDir()).path, submission.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    final catalog = await loadCatalog();
    await _saveCatalog(
      AssignmentSubmissionCatalog(submissions: catalog.submissions.where((s) => s.id != submission.id).toList()),
    );
  }
}
