import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/assignment_submission.dart';

/// Assignment Submission, Stages 5-7: consolidates the cover page,
/// transcribed body, and transcribed references into one PDF; bundles
/// every originally-captured page image into a separate compressed
/// backup; and records a SHA-256 hash + submission timestamp as this
/// submission's integrity proof. Entirely on-device — no network.
class AssignmentSubmissionDocumentService {
  Future<File> _writeToSubmissionDir(Directory dir, String fileName, List<int> bytes) async {
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Stage 5 — the consolidated PDF: (a) Cover Page — the templated
  /// fields, followed by the original handwritten cover photo attached
  /// as-is (never redrawn); (b) Introduction/Main Body/Conclusion, from
  /// Stage 2's transcription; (c) Reference Page, from Stage 4's
  /// transcription (omitted entirely when [ReferenceSystem.none] was
  /// chosen, rather than showing an empty section).
  ///
  /// Stage 6's timestamp requirement is embedded here, in the PDF's own
  /// metadata (`keywords`) — decided once, before this document's bytes
  /// are ever hashed, so there's no circularity with [computeSha256].
  /// The hash itself is never embedded inside the PDF it describes (that
  /// would require hashing the document, then re-hashing after embedding
  /// the hash, which never actually terminates) — it's recorded
  /// alongside the timestamp on the submission record and shown to the
  /// student on the Stage 9 confirmation screen instead.
  Future<File> generateConsolidatedPdf({
    required AssignmentSubmission submission,
    required Directory submissionDir,
    required DateTime submittedAt,
  }) async {
    final doc = pw.Document(
      title: submission.assignmentTitle.isEmpty ? 'Assignment Submission' : submission.assignmentTitle,
      subject: 'Assignment submission by ${submission.studentName}',
      keywords: 'submittedAt:${submittedAt.toIso8601String()}',
    );

    final coverPhotoFile =
        submission.coverPhotoFileName != null ? File(p.join(submissionDir.path, submission.coverPhotoFileName!)) : null;
    final coverPhotoImage =
        coverPhotoFile != null && await coverPhotoFile.exists() ? pw.MemoryImage(await coverPhotoFile.readAsBytes()) : null;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Center(
            child: pw.Text('COVER PAGE', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 16),
          _coverField('Student Name', submission.studentName),
          _coverField('ID / Registration Number', submission.idNumber),
          _coverField('Course', submission.course),
          _coverField('Subject', submission.subject),
          _coverField('Assignment Title', submission.assignmentTitle),
          _coverField('Lecturer / Teacher Name', submission.teacherName),
          _coverField('Date', submission.date),
          _coverField('Institution', submission.institution),
          if (coverPhotoImage != null) ...[
            pw.SizedBox(height: 20),
            pw.Text('Original Cover Page (as submitted)', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.Image(coverPhotoImage, fit: pw.BoxFit.contain),
          ],
          pw.SizedBox(height: 20),
          pw.Text('INTRODUCTION / MAIN BODY / CONCLUSION', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Divider(thickness: 0.5),
          for (final block in submission.transcribedBody) _bodyBlock(block),
          if (submission.referenceSystem != ReferenceSystem.none && submission.transcribedReferences.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            pw.Text('REFERENCES', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.Text('(${submission.referenceSystem.label})', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            pw.Divider(thickness: 0.5),
            for (final entry in submission.transcribedReferences) _referenceEntry(entry),
          ],
        ],
      ),
    );

    final bytes = await doc.save();
    return _writeToSubmissionDir(submissionDir, 'submission.pdf', bytes);
  }

  pw.Widget _coverField(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 6),
        child: pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(text: '$label: ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11)),
              pw.TextSpan(text: value.isEmpty ? '(not provided)' : value, style: const pw.TextStyle(fontSize: 11)),
            ],
          ),
        ),
      );

  pw.Widget _bodyBlock(AssignmentBodyBlock block) {
    switch (block.type) {
      case AssignmentBodyBlockType.heading:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
          child: pw.Text(block.text, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        );
      case AssignmentBodyBlockType.subheading:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8, bottom: 4),
          child: pw.Text(block.text, style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold)),
        );
      case AssignmentBodyBlockType.bullet:
      case AssignmentBodyBlockType.numbered:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(left: 10, bottom: 4),
          child: pw.Bullet(text: block.text, style: const pw.TextStyle(fontSize: 11)),
        );
      case AssignmentBodyBlockType.paragraph:
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Text(block.text, style: const pw.TextStyle(fontSize: 11)),
        );
    }
  }

  pw.Widget _referenceEntry(String entry) {
    // Reproduces the *asterisks* italics marker the transcription prompt
    // asks for — a plain pw.Text can't mix styles inline without
    // TextSpans, so split on the marker and alternate normal/italic runs.
    final parts = entry.split('*');
    final spans = <pw.TextSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      spans.add(pw.TextSpan(
        text: parts[i],
        style: pw.TextStyle(fontSize: 10.5, fontStyle: i.isOdd ? pw.FontStyle.italic : pw.FontStyle.normal),
      ));
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.RichText(text: pw.TextSpan(children: spans)),
    );
  }

  /// Stage 5's "separate compressed image bundle" — every originally
  /// captured page (cover + body + references), zipped as-is, the
  /// authoritative backup independent of how the transcription/PDF
  /// turned out. Uses the already-installed `archive` package (no new
  /// dependency), same as this app's other document services.
  Future<File> generateImageBundle({
    required AssignmentSubmission submission,
    required Directory submissionDir,
  }) async {
    final archive = Archive();
    void addIfExists(String fileName) {
      final file = File(p.join(submissionDir.path, fileName));
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        archive.addFile(ArchiveFile(fileName, bytes.length, bytes));
      }
    }

    if (submission.coverPhotoFileName != null) addIfExists(submission.coverPhotoFileName!);
    for (final name in submission.bodyPageFileNames) {
      addIfExists(name);
    }
    for (final name in submission.referencePageFileNames) {
      addIfExists(name);
    }

    final zipBytes = ZipEncoder().encode(archive);
    return _writeToSubmissionDir(submissionDir, 'original_pages.zip', zipBytes);
  }

  /// Stage 6 — SHA-256 of the final PDF's actual bytes on disk, computed
  /// once consolidation is otherwise complete.
  Future<String> computeSha256(File pdfFile) async {
    final bytes = await pdfFile.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Stage 7 — a permanent, independent-of-transmission copy: both the
  /// PDF and the image bundle already live in [submissionDir] (part of
  /// [AssignmentSubmissionRepository]'s own on-device storage, never
  /// cleared by a successful or failed send), so this is really just
  /// confirming that path stays true — this app's application-documents
  /// directory, unlike a share-sheet temp file, is never auto-cleared by
  /// the OS. Exposed as its own method so a caller can name explicitly
  /// *why* nothing further needs to happen after Stage 5/6.
  Directory permanentCopyLocation(Directory submissionDir) => submissionDir;
}
