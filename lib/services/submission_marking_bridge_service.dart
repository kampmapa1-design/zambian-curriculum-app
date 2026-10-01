import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../models/marking_script.dart';
import '../models/teacher_submission.dart';
import 'marking_script_repository.dart';
import 'teacher_dashboard_service.dart';

class SubmissionMarkingBridgeUnavailable implements Exception {
  final String message;
  const SubmissionMarkingBridgeUnavailable(this.message);
  @override
  String toString() => message;
}

/// "Mark Submitted Assignment" (owner request, 2026-09-28) — the bridge
/// from a Submissions Dashboard row into any AI marking engine (Chief
/// Marker / Concise Marking / Stable Marker), for Assignment Submission,
/// which had no marking bridge of any kind before this. Real architectural
/// gap this closes: unlike Test Submission's own on-device "Send to
/// Marking" (which reads page images the SAME device already has locally),
/// a Dashboard row may have been RECEIVED on a different device than the
/// one that captured it — the only thing available here is the cloud copy,
/// and AssignmentSubmissionScreen only ever uploads ONE merged PDF of the
/// photographed pages (see its own upload call), never individual page
/// images. So this downloads that PDF and rasterizes it back into
/// per-page image files on-device — MarkingScriptRepository, and Concise
/// Marking's own on-image annotation, both need real per-page images, not
/// a PDF.
///
/// Disclosed scoping limit: a script created this way has no reverse-link
/// back to this Dashboard row (unlike Test Submission's own
/// `markingScriptId`/`findByMarkingScriptId` bridge) — [TeacherSubmission]
/// carries no student email/WhatsApp at all today, so there is nothing yet
/// for a later "send feedback" action to address even if the link existed.
/// Wiring that up is real, separate follow-up work (would need the
/// `submitToTeacherDashboard` Cloud Function and Firestore schema to also
/// carry the student's contact details).
class SubmissionMarkingBridgeService {
  SubmissionMarkingBridgeService({TeacherDashboardService? dashboardService, MarkingScriptRepository? markingScriptRepository})
      : _dashboardService = dashboardService ?? TeacherDashboardService(),
        _markingScriptRepository = markingScriptRepository ?? MarkingScriptRepository();

  final TeacherDashboardService _dashboardService;
  final MarkingScriptRepository _markingScriptRepository;

  Future<MarkingScript> sendToMarking({
    required TeacherSubmission submission,
    required CandidateGender gender,
  }) async {
    final imageFile = submission.files.where((f) => f.filename.toLowerCase().endsWith('.pdf')).firstOrNull;
    if (imageFile == null) {
      throw const SubmissionMarkingBridgeUnavailable('This submission has no photographed pages to mark.');
    }

    final url = await _dashboardService.fileUrl(submission, imageFile);
    final http.Response response;
    try {
      response = await http.get(Uri.parse(url));
    } catch (_) {
      throw const SubmissionMarkingBridgeUnavailable('Could not download the photographed pages.');
    }
    if (response.statusCode != 200) {
      throw const SubmissionMarkingBridgeUnavailable('Could not download the photographed pages.');
    }

    final pageFiles = await _rasterizePdfPages(response.bodyBytes);
    if (pageFiles.isEmpty) {
      throw const SubmissionMarkingBridgeUnavailable('The photographed pages could not be read from the submitted PDF.');
    }

    final nameParts = submission.studentName.trim().split(RegExp(r'\s+'));
    final firstName = nameParts.isEmpty ? '' : nameParts.first;
    final surname = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';

    final nextNumber = await _markingScriptRepository.nextScriptNumber();
    return _markingScriptRepository.saveScript(
      firstName: firstName,
      surname: surname,
      gender: gender,
      scriptNumber: nextNumber,
      subjectName: submission.subjectName,
      gradeName: submission.className,
      capturedPageFiles: pageFiles,
    );
  }

  Future<List<File>> _rasterizePdfPages(Uint8List pdfBytes) async {
    final tempDir = await getTemporaryDirectory();
    final sessionDir = Directory(p.join(tempDir.path, 'submission_marking_bridge_${DateTime.now().millisecondsSinceEpoch}'));
    if (!await sessionDir.exists()) await sessionDir.create(recursive: true);

    final files = <File>[];
    var pageNumber = 0;
    await for (final page in Printing.raster(pdfBytes, dpi: 200)) {
      pageNumber++;
      final png = await page.toPng();
      final file = File(p.join(sessionDir.path, 'page_${pageNumber.toString().padLeft(2, '0')}.png'));
      await file.writeAsBytes(png, flush: true);
      files.add(file);
    }
    return files;
  }
}
