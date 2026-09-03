import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'assignment_submission_email_service.dart';
import 'report_class_repository.dart';
import 'report_form_document_service.dart';

/// The Report Form Pipeline's data safeguard, per explicit request: the
/// on-device SQLite copy of a class always exists the moment any screen
/// saves anything (that's just how `ReportClassRepository` works — nothing
/// extra needed there) — this is the SECOND copy, a fresh whole-class
/// snapshot emailed to a school-records address whenever real checkpoints
/// happen (a subject score-sheet upload commits, an Omitted Entry, a
/// learner edit, a report form is generated). Reuses the exact same
/// document [ReportFormDocumentService.generateBroadMarkSheetDocx] already
/// builds for Stage 14's "Print" — no separate backup-format logic.
///
/// **Never blocks, never throws to its caller**: every checkpoint call is
/// fire-and-forget (`unawaited(...)` at the call site) — a backup email
/// failing (offline, a bad address) must never interrupt the real work a
/// teacher is doing. A missing [ReportClass.backupEmail] simply means
/// [maybeBackup] returns `false` without attempting anything; the calling
/// screen is what shows the "you should set a backup email" reminder (see
/// [BackupReminder]), not this service.
class ReportClassBackupService {
  ReportClassBackupService({
    ReportClassRepository? repository,
    ReportFormDocumentService? documentService,
    AssignmentSubmissionEmailService? emailService,
  })  : _repository = repository ?? ReportClassRepository(),
        _documentService = documentService ?? ReportFormDocumentService(),
        _emailService = emailService ?? AssignmentSubmissionEmailService();

  final ReportClassRepository _repository;
  final ReportFormDocumentService _documentService;
  final AssignmentSubmissionEmailService _emailService;

  /// Builds a fresh Broad Mark Sheet snapshot and emails it to the class's
  /// configured backup address, if any. Returns true only on a real,
  /// confirmed send — false for "no backup email configured" AND for any
  /// failure along the way (both are silent to the caller; see this
  /// class's own doc comment on why).
  Future<bool> maybeBackup(int classId, {ReportClassRepository? repository}) async {
    final repo = repository ?? _repository;
    try {
      final reportClass = await repo.getClass(classId);
      final backupEmail = reportClass?.backupEmail;
      if (reportClass == null || backupEmail == null || backupEmail.trim().isEmpty) return false;

      final sheet = await repo.loadBroadMarkSheet(classId);
      final resolved = <int, Map<int, double?>>{};
      for (final learner in sheet.learners) {
        final row = <int, double?>{};
        for (final subject in sheet.subjects) {
          row[subject.id] = await repo.scoreFor(learner.id, subject, allSubjects: sheet.subjects);
        }
        resolved[learner.id] = row;
      }

      final bytes = _documentService.generateBroadMarkSheetDocx(
        reportClass: reportClass,
        learners: sheet.learners,
        subjects: sheet.subjects,
        scoresByLearnerThenSubject: resolved,
      );
      final dir = await getTemporaryDirectory();
      final safeGrade = reportClass.classGrade.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      final file = File(p.join(dir.path, 'class_backup_${classId}_$safeGrade.docx'));
      await file.writeAsBytes(bytes, flush: true);

      await _emailService.send(
        recipientEmail: backupEmail,
        studentName: reportClass.classGrade,
        assignmentTitle: 'Class Records Backup — ${reportClass.classGrade}, ${reportClass.term} — '
            '${reportClass.schoolName}',
        submissionHash: sha256.convert(bytes).toString(),
        submittedAt: DateTime.now(),
        attachments: [EmailAttachmentFile(file: file, filename: p.basename(file.path))],
        submissionKind: 'classBackup',
      );
      return true;
    } catch (_) {
      // Silent, deliberately — see this class's own doc comment. The
      // on-device copy is always safe regardless of whether this succeeds.
      return false;
    }
  }
}
