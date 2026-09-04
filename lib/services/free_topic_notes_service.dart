import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/slide_outline.dart';
import '../utils/text_utils.dart';
import 'auth_service.dart';

enum FreeTopicFormat {
  paragraph,
  bulletin,
  slides;

  String get wireValue => name;
}

/// Either a plain-text result (paragraph/bulletin) or a slide outline
/// (slides) — exactly one of [text]/[outline] is set, matching whichever
/// [FreeTopicFormat] was requested.
class FreeTopicNotesResult {
  final String? text;
  final SlideOutline? outline;
  const FreeTopicNotesResult({this.text, this.outline});
}

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request" — either way there's a user-facing message to show.
class FreeTopicNotesUnavailable implements Exception {
  final String message;
  const FreeTopicNotesUnavailable(this.message);
  @override
  String toString() => message;
}

/// Calls the `generateFreeTopicNotes` Cloud Function — "Generate Notes &
/// Slides by Topic" (2026-09-04): a topic the teacher types directly, not
/// tied to any bundled syllabus content. Needs a live connection, same as
/// every other AI-backed service in this app, and there is no offline
/// fallback possible here (unlike the syllabus-grounded Teaching Notes
/// path) since there's no bundled data for an arbitrary typed topic to
/// fall back to.
class FreeTopicNotesService {
  FreeTopicNotesService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<FreeTopicNotesResult> generate({required String topic, required FreeTopicFormat format}) async {
    if (!await isOnline) {
      throw const FreeTopicNotesUnavailable("You're offline. Connect to the internet to generate notes for this topic.");
    }

    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable('generateFreeTopicNotes');
    try {
      final result = await callable.call<Map<Object?, Object?>>({
        'topic': topic,
        'format': format.wireValue,
      });
      final data = result.data;
      if (format == FreeTopicFormat.slides) {
        final slidesRaw = (data['slides'] as List?) ?? const [];
        final slides = [
          for (final s in slidesRaw.cast<Map<Object?, Object?>>())
            Slide(
              title: stripMarkdownArtifacts(s['title'] as String? ?? ''),
              bullets: [for (final b in (s['bullets'] as List?)?.cast<String>() ?? const []) stripMarkdownArtifacts(b)],
            ),
        ];
        return FreeTopicNotesResult(
          outline: SlideOutline(deckTitle: stripMarkdownArtifacts(data['deckTitle'] as String? ?? topic), slides: slides),
        );
      }
      return FreeTopicNotesResult(text: stripMarkdownArtifacts(data['text'] as String? ?? ''));
    } on FirebaseFunctionsException catch (e) {
      throw FreeTopicNotesUnavailable(e.message ?? 'Failed to generate notes.');
    }
  }
}
