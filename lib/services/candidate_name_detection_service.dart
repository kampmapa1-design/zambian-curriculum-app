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

/// SUSPENDED (2026-08-30) — no longer called anywhere in the app.
/// `detectCandidateName` sent one full-resolution page image to Gemini per
/// script purely to pre-fill a name field a teacher could type in a few
/// seconds anyway; at real usage volume it turned out to be a significant,
/// easily-avoidable share of this app's AI cost (see the cost sizing that
/// prompted this). BurstCaptureScreen and ScriptBatchCaptureScreen now ask
/// for name/ID/class up front via a plain manual entry form instead.
/// Left in place (Dart service + `detectCandidateName` Cloud Function,
/// still deployed) rather than deleted, in case a genuinely cheap
/// detection path is worth revisiting later — but nothing calls it, so it
/// costs nothing sitting idle.
///
/// AI-Assisted Marking, Stage D (as originally built) — calls
/// `detectCandidateName` with a script's first captured page to pre-fill
/// the (always-editable) name fields during capture. Pure convenience: any
/// failure here (offline, function error) is swallowed and treated as
/// "nothing detected" rather than interrupting the capture session a
/// teacher is mid-way through.
class CandidateNameDetectionService {
  CandidateNameDetectionService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<DetectedCandidateName> detect(File pageImage) async {
    try {
      // Hard backstop covering EVERYTHING, including the connectivity
      // check itself — a version that only wrapped auth+upload left the
      // connectivity-plugin call free to stall ahead of the timeout,
      // defeating it entirely. Nothing here runs outside this timeout.
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
    if (!await isOnline) return const DetectedCandidateName(firstName: '', surname: '');
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
