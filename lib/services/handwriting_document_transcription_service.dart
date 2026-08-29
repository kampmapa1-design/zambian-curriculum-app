import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request", and for a response that doesn't match the
/// expected shape.
class HandwritingDocumentTranscriptionUnavailable implements Exception {
  final String message;
  const HandwritingDocumentTranscriptionUnavailable(this.message);
  @override
  String toString() => message;
}

enum DocumentBlockType { heading, subheading, paragraph, bullet, numbered }

/// One piece of the transcribed document's content, in reading order.
class DocumentBlock {
  final DocumentBlockType type;
  final String text;

  const DocumentBlock({required this.type, required this.text});

  static DocumentBlockType? _typeFromWire(Object? value) {
    if (value is! String) return null;
    for (final t in DocumentBlockType.values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

/// A generically-transcribed document — free-form content (notes, a
/// letter, an essay, anything with real paragraph/heading/list structure),
/// unlike [TranscribedTable] which is specifically for rows-and-columns
/// lists. See HandwritingDocumentService for how this becomes an actual
/// editable .docx.
class TranscribedDocument {
  final String title;
  final List<DocumentBlock> blocks;
  final String notes;

  const TranscribedDocument({required this.title, required this.blocks, required this.notes});
}

/// "Handwriting to Word Document Conversion" — reads whatever was
/// genuinely written on the photographed/uploaded page(s) (any
/// structure — notes, a letter, an essay) and returns it as a sequence
/// of typed blocks, calling `transcribeHandwrittenDocument`.
class HandwritingDocumentTranscriptionService {
  HandwritingDocumentTranscriptionService({FirebaseFunctions? functions})
      : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<TranscribedDocument> transcribe(List<File> pageFiles, {void Function(String status)? onProgress}) async {
    // Tracks the last progress step reached, so a timeout error names
    // exactly where it got stuck — see
    // HandwrittenListTranscriptionService.transcribe for the full
    // reasoning behind this pattern (a real "gets stuck after Done" bug
    // was traced this way).
    var lastStatus = 'starting';
    void track(String status) {
      lastStatus = status;
      onProgress?.call(status);
    }

    // Hard backstop covering EVERYTHING, including the connectivity check
    // itself — nothing in this method runs outside this timeout, so it
    // always either finishes or surfaces a clear, actionable error.
    try {
      return await _run(pageFiles, track).timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw HandwritingDocumentTranscriptionUnavailable(
          'This is taking too long and may be stuck (last step: "$lastStatus"). Check your mobile data/Wi-Fi '
          'signal and try again.',
        ),
      );
    } on HandwritingDocumentTranscriptionUnavailable {
      rethrow;
    } catch (error) {
      throw HandwritingDocumentTranscriptionUnavailable('Could not transcribe this document (last step: "$lastStatus"): $error');
    }
  }

  Future<TranscribedDocument> _run(List<File> pageFiles, void Function(String status) onProgress) async {
    onProgress('Checking connection…');
    if (!await isOnline) {
      throw const HandwritingDocumentTranscriptionUnavailable(
        "You're offline. Connect to the internet to convert this document.",
      );
    }

    onProgress('Signing in…');
    await AuthService.instance.ensureSignedIn();

    onProgress('Preparing pages…');
    final callable = _functions.httpsCallable(
      'transcribeHandwrittenDocument',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 85)),
    );

    Object? rawData;
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      onProgress('Reading the document with AI…');
      final result = await callable.call<Object?>({'pageImagesBase64': images});
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw HandwritingDocumentTranscriptionUnavailable(e.message ?? 'Failed to transcribe this document.');
    }

    // Fully defensive — `is` checks rather than blind casts, at every
    // level. See HandwrittenListTranscriptionService.transcribe for the
    // bug this pattern was originally added to fix.
    if (rawData is! Map) {
      throw const HandwritingDocumentTranscriptionUnavailable('The transcription response was in an unexpected format.');
    }
    final data = rawData;

    final title = data['title'];
    final blocksRaw = data['blocks'];
    if (blocksRaw is! List) {
      throw const HandwritingDocumentTranscriptionUnavailable('The transcription response was in an unexpected format.');
    }

    final blocks = <DocumentBlock>[];
    for (final b in blocksRaw) {
      if (b is! Map) continue;
      final type = DocumentBlock._typeFromWire(b['type']) ?? DocumentBlockType.paragraph;
      final text = b['text'];
      if (text is String && text.trim().isNotEmpty) {
        blocks.add(DocumentBlock(type: type, text: text));
      }
    }
    if (blocks.isEmpty) {
      throw const HandwritingDocumentTranscriptionUnavailable('No readable content could be found on that document.');
    }

    final notes = data['notes'];
    return TranscribedDocument(
      title: title is String && title.trim().isNotEmpty ? title : 'Converted Document',
      blocks: blocks,
      notes: notes is String ? notes : '',
    );
  }
}
