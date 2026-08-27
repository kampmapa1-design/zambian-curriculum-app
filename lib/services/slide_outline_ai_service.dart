import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/slide_outline.dart';
import '../utils/text_utils.dart';
import 'auth_service.dart';

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request" — either way there's a user-facing message to show.
class SlideOutlineUnavailable implements Exception {
  final String message;
  const SlideOutlineUnavailable(this.message);
  @override
  String toString() => message;
}

/// Calls a `generateSlideOutline` Cloud Function for an AI-condensed slide
/// deck, mirroring [TeachingNotesService]'s pattern exactly. Needs a live
/// connection (it reaches a backend that calls an AI provider — Gemini as of
/// 2026-08-26, see that function's own comment in
/// firebase/functions/src/index.ts) and, like teaching notes, needs
/// Firebase's paid Blaze plan enabled with that function actually deployed —
/// until then this fails gracefully and [OfflineSlideOutlineService] remains
/// the working path.
class SlideOutlineAiService {
  SlideOutlineAiService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<SlideOutline> generate({
    required String topic,
    String? subtopic,
    required String notesText,
    required String notesFormat,
  }) async {
    if (!await isOnline) {
      throw const SlideOutlineUnavailable("You're offline. Connect to the internet to generate AI-condensed slides.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable('generateSlideOutline');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'topic': topic,
        if (subtopic != null) 'subtopic': subtopic,
        'notesText': notesText,
        'notesFormat': notesFormat,
      });
      return _outlineFromMap(result.data, fallbackTitle: subtopic ?? topic);
    } on FirebaseFunctionsException catch (e) {
      throw SlideOutlineUnavailable(e.message ?? 'Failed to generate AI-condensed slides.');
    }
  }

  SlideOutline _outlineFromMap(Map<Object?, Object?> map, {required String fallbackTitle}) {
    final slidesRaw = (map['slides'] as List?) ?? const [];
    final slides = [
      for (final s in slidesRaw.cast<Map<Object?, Object?>>())
        Slide(
          // Safety net: strip any Markdown the model slipped in despite the
          // plain-text instruction, same as the teaching-notes AI path.
          title: stripMarkdownArtifacts(s['title'] as String? ?? ''),
          bullets: [for (final b in (s['bullets'] as List?)?.cast<String>() ?? const []) stripMarkdownArtifacts(b)],
        ),
    ];
    return SlideOutline(
      deckTitle: stripMarkdownArtifacts(map['deckTitle'] as String? ?? fallbackTitle),
      slides: slides,
    );
  }
}
