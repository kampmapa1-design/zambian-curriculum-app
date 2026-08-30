import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Extracts plain text from a PDF's raw bytes entirely on-device — no
/// network, no API call, works offline. This is the fallback path used by
/// [SubjectContentRepository.store] when AI extraction
/// ([SubjectContentExtractionService]) can't run right now (no
/// connectivity, or a transient Cloud Function failure): it gets a Teaching
/// Module usable for lesson/notes generation immediately, rather than
/// leaving it as an inert raw PDF until the next time the app happens to be
/// online. AI extraction stays the *primary* path whenever there's a
/// connection — it generally produces cleaner text (it drops running
/// headers/footers, page numbers and OCRs scanned pages) — so anything
/// captured on-device this way is flagged
/// ([SubjectContentItem.extractedOnDevice]) for a one-time quality upgrade
/// the next time [SubjectContentRepository.migrateLegacyItems] runs online.
///
/// Only works on PDFs that already carry an embedded text layer (i.e. not a
/// pure image scan with no OCR) — which covers essentially every real CDC
/// syllabus/module/scheme PDF, all digitally typeset. A scanned-image-only
/// PDF returns null here, same as any other "nothing usable yet" case, and
/// falls through to the existing raw-PDF-pending-later-conversion path.
class OnDevicePdfTextExtractionService {
  /// Returns extracted text, or null if nothing usable could be pulled out
  /// (corrupt file, encrypted with no owner password, or no text layer).
  /// Never throws — every failure mode is caught and treated as "no text
  /// available on-device", the same as any other unusable input.
  String? extractText(List<int> pdfBytes) {
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: pdfBytes);
      final text = PdfTextExtractor(document).extractText();
      final cleaned = text.trim();
      return cleaned.isEmpty ? null : cleaned;
    } catch (e) {
      debugPrint('OnDevicePdfTextExtractionService: extraction failed ($e)');
      return null;
    } finally {
      document?.dispose();
    }
  }
}
