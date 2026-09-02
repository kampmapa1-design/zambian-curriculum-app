import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/test_submission.dart';

/// Test Submission, Stages 4-6: consolidates the transcribed, question-
/// tagged answer segments into one PDF; bundles every originally-captured
/// page image into a separate compressed backup; and records a SHA-256
/// hash + submission timestamp as this submission's integrity proof.
/// Entirely on-device — no network. Mirrors
/// AssignmentSubmissionDocumentService's structure exactly.
class TestSubmissionDocumentService {
  Future<File> _writeToSubmissionDir(Directory dir, String fileName, List<int> bytes) async {
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Stage 4 — segments are rendered in transcription order (page order),
  /// each tagged with its detected question number, never regrouped —
  /// preserving both page order and question-number structure at once,
  /// exactly as specified, rather than sorting/merging by question number
  /// (which would silently reorder pages).
  ///
  /// Stage 6's timestamp is embedded here, in the PDF's own metadata
  /// (`keywords`), decided before this document's bytes are ever hashed —
  /// same non-circular approach as Assignment Submission's document
  /// service (see its doc comment for the full reasoning).
  Future<File> generateConsolidatedPdf({
    required TestSubmission submission,
    required Directory submissionDir,
    required DateTime submittedAt,
  }) async {
    final title = submission.subjectName.isEmpty ? 'Test Submission' : '${submission.subjectName} Test Submission';
    final doc = pw.Document(
      title: title,
      subject: 'Test submission by ${submission.studentName}',
      keywords: 'submittedAt:${submittedAt.toIso8601String()}',
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          pw.Center(
            child: pw.Text('TEST SUBMISSION', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          ),
          pw.SizedBox(height: 16),
          _coverField('Student Name', submission.studentName),
          _coverField('Subject', submission.subjectName),
          _coverField('Grade', submission.gradeName),
          _coverField('School / Institution', submission.institution),
          _coverField('Submitted', submittedAt.toLocal().toString()),
          pw.SizedBox(height: 20),
          pw.Text('ANSWERS', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Divider(thickness: 0.5),
          for (final segment in submission.segments) _segment(segment),
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

  pw.Widget _segment(TestAnswerSegment segment) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 10),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              segment.questionNumber,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: segment.questionNumber == 'Unlabeled' ? PdfColors.grey600 : PdfColors.black,
              ),
            ),
            pw.SizedBox(height: 3),
            pw.Text(segment.text, style: const pw.TextStyle(fontSize: 11)),
          ],
        ),
      );

  /// Stage 4's "attach the compressed original images as the authoritative
  /// backup" — every originally captured page, zipped as-is. Uses the
  /// already-installed `archive` package (no new dependency).
  Future<File> generateImageBundle({
    required TestSubmission submission,
    required Directory submissionDir,
  }) async {
    final archive = Archive();
    for (final name in submission.pageFileNames) {
      final file = File(p.join(submissionDir.path, name));
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
    }

    final zipBytes = ZipEncoder().encode(archive);
    return _writeToSubmissionDir(submissionDir, 'original_pages.zip', zipBytes);
  }

  /// Stage 6 — SHA-256 of the final PDF's actual bytes on disk.
  Future<String> computeSha256(File pdfFile) async {
    final bytes = await pdfFile.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// Stage 5 — both the PDF and image bundle already live permanently in
  /// [submissionDir] (part of [TestSubmissionRepository]'s own on-device
  /// storage, never cleared by a successful or failed send); exposed as
  /// its own method so a caller can name explicitly why nothing further
  /// needs to happen after Stage 4/6.
  Directory permanentCopyLocation(Directory submissionDir) => submissionDir;
}
