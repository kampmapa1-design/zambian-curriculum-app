import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'auth_service.dart';

/// A detected name, or both fields empty if none was found — never
/// throws for "no name visible", only for a genuine connectivity/function
/// failure (see [detect]'s try/catch, which treats detection failure as
/// "nothing found" rather than blocking capture over a convenience
/// feature).
class DetectedCandidateName {
  final String firstName;
  final String surname;

  const DetectedCandidateName({required this.firstName, required this.surname});

  bool get isEmpty => firstName.isEmpty && surname.isEmpty;
}

/// AI-Assisted Marking, Stage D — calls `detectCandidateName` with a
/// script's first captured page to pre-fill the (always-editable) name
/// fields during capture. Pure convenience: any failure here (offline,
/// function error) is swallowed and treated as "nothing detected" rather
/// than interrupting the capture session a teacher is mid-way through -
/// see BurstCaptureScreen, which calls this fire-and-forget.
class CandidateNameDetectionService {
  CandidateNameDetectionService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<DetectedCandidateName> detect(File pageImage) async {
    try {
      if (!await isOnline) return const DetectedCandidateName(firstName: '', surname: '');
      // Hard backstop, same reasoning as HandwrittenListTranscriptionService
      // — a stalled auth handshake or plugin call must not hang the small
      // "detecting…" spinner next to the name field forever.
      return await _doDetect(pageImage).timeout(
        const Duration(seconds: 60),
        onTimeout: () => const DetectedCandidateName(firstName: '', surname: ''),
      );
    } catch (_) {
      // Convenience feature only - never block or alarm the teacher over
      // a failed auto-detect attempt, they can just type the name.
      return const DetectedCandidateName(firstName: '', surname: '');
    }
  }

  Future<DetectedCandidateName> _doDetect(File pageImage) async {
    await AuthService.instance.ensureSignedIn();

    final callable = _functions.httpsCallable(
      'detectCandidateName',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 50)),
    );
    final bytes = await pageImage.readAsBytes();
    final result = await callable.call<Map<Object?, Object?>>({'imageBase64': base64Encode(bytes)});
    return DetectedCandidateName(
      firstName: result.data['firstName'] as String? ?? '',
      surname: result.data['surname'] as String? ?? '',
    );
  }
}
