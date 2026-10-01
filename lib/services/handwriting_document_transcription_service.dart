import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';
import 'metered_call.dart';

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

/// One suspected (not yet confirmed) paragraph break inside an existing
/// 'paragraph' block — Assignment Submission's indentation detection only
/// (2026-09-28, per explicit request; see [HandwritingDocumentTranscriptionService.transcribe]'s
/// own `detectParagraphIndentation` parameter). [splitAtText] is a real,
/// verbatim substring of that block's own [DocumentBlock.text] — where to
/// cut it if the student confirms this really is a new paragraph.
class AmbiguousParagraphBreak {
  final int blockIndex;
  final String splitAtText;

  const AmbiguousParagraphBreak({required this.blockIndex, required this.splitAtText});
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

  /// Always empty unless [HandwritingDocumentTranscriptionService.transcribe]
  /// was called with `detectParagraphIndentation: true` — the plain
  /// Handwriting-to-Word-Document feature never sets that, so this stays
  /// empty for it, same as before this field existed.
  final List<AmbiguousParagraphBreak> ambiguousParagraphBreaks;

  const TranscribedDocument({
    required this.title,
    required this.blocks,
    required this.notes,
    this.ambiguousParagraphBreaks = const [],
  });
}

/// "Handwriting to Word Document Conversion" — reads whatever was
/// genuinely written on the photographed/uploaded page(s) (any
/// structure — notes, a letter, an essay) and returns it as a sequence
/// of typed blocks, calling `transcribeHandwrittenDocument`.
class HandwritingDocumentTranscriptionService {
  HandwritingDocumentTranscriptionService({FirebaseFunctions? functions}) : _providedFunctions = functions;

  // Lazy: resolving FirebaseFunctions.instance needs Firebase.initializeApp() to have
  // succeeded; constructing this service must never throw just because it hasn't.
  final FirebaseFunctions? _providedFunctions;
  FirebaseFunctions get _functions => _providedFunctions ?? FirebaseFunctions.instance;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// [detectParagraphIndentation]: Assignment Submission's main-body
  /// transcription only (2026-09-28, per explicit request) — analyzes each
  /// line's starting position to detect paragraph breaks the plain
  /// "keep a paragraph as one block" default would otherwise miss. False
  /// (every other caller, unchanged) means the server never even sees this
  /// flag, so its prompt/schema/behavior stays exactly as before.
  Future<TranscribedDocument> transcribe(
    List<File> pageFiles, {
    bool detectParagraphIndentation = false,
    void Function(String status)? onProgress,
  }) async {
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
      return await _run(pageFiles, detectParagraphIndentation, track).timeout(
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

  Future<TranscribedDocument> _run(
    List<File> pageFiles,
    bool detectParagraphIndentation,
    void Function(String status) onProgress,
  ) async {
    onProgress('Checking connection…');
    if (!await isOnline) {
      throw const HandwritingDocumentTranscriptionUnavailable(
        "You're offline. Connect to the internet to convert this document.",
      );
    }

    onProgress('Signing in…');
    await AuthService.instance.ensureSignedIn();

    onProgress('Preparing pages…');
    final callable = meteredCallable(_functions, 'transcribeHandwrittenDocument',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 85)),
    );

    Object? rawData;
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      onProgress('Reading the document with AI…');
      final result = await callable.call<Object?>({
        'pageImagesBase64': images,
        if (detectParagraphIndentation) 'detectParagraphIndentation': true,
      });
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
    // Maps the server's own 0-based index into ITS `blocks` array (what
    // `ambiguousParagraphBreaks[].blockIndex` below refers to) to this
    // list's final index — needed because a malformed/empty entry is
    // skipped here, which would otherwise silently shift every later
    // index and point a suspected break at the wrong block.
    final serverIndexToLocal = <int, int>{};
    for (var i = 0; i < blocksRaw.length; i++) {
      final b = blocksRaw[i];
      if (b is! Map) continue;
      final type = DocumentBlock._typeFromWire(b['type']) ?? DocumentBlockType.paragraph;
      final text = b['text'];
      if (text is String && text.trim().isNotEmpty) {
        serverIndexToLocal[i] = blocks.length;
        blocks.add(DocumentBlock(type: type, text: text));
      }
    }
    if (blocks.isEmpty) {
      throw const HandwritingDocumentTranscriptionUnavailable('No readable content could be found on that document.');
    }

    final ambiguousRaw = data['ambiguousParagraphBreaks'];
    final ambiguousBreaks = <AmbiguousParagraphBreak>[];
    if (ambiguousRaw is List) {
      for (final entry in ambiguousRaw) {
        if (entry is! Map) continue;
        final serverIndex = entry['blockIndex'];
        final splitAtText = entry['splitAtText'];
        if (serverIndex is! num || splitAtText is! String || splitAtText.trim().isEmpty) continue;
        final localIndex = serverIndexToLocal[serverIndex.toInt()];
        // Only ever meaningful against a real 'paragraph' block this app
        // actually kept, and only when the anchor text is really there to
        // find — never guessed if either check fails.
        if (localIndex == null || blocks[localIndex].type != DocumentBlockType.paragraph) continue;
        if (!blocks[localIndex].text.contains(splitAtText)) continue;
        ambiguousBreaks.add(AmbiguousParagraphBreak(blockIndex: localIndex, splitAtText: splitAtText));
      }
    }

    final notes = data['notes'];
    return TranscribedDocument(
      title: title is String && title.trim().isNotEmpty ? title : 'Converted Document',
      blocks: blocks,
      ambiguousParagraphBreaks: ambiguousBreaks,
      notes: notes is String ? notes : '',
    );
  }
}
