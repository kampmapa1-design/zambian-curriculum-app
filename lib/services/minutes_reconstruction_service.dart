import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/minutes_session.dart';
import 'auth_service.dart';

/// Thrown for both "can't reach the function" (offline) and "the function
/// rejected the request", and for a response that doesn't match the
/// expected shape. Same discipline as the other AI-call services in this
/// app — see HandwrittenListTranscriptionService.
class MinutesReconstructionUnavailable implements Exception {
  final String message;
  const MinutesReconstructionUnavailable(this.message);
  @override
  String toString() => message;
}

class ReconstructedMinutes {
  final String meetingTitle;
  final List<MinutesSection> sections;
  final String notes;

  const ReconstructedMinutes({required this.meetingTitle, required this.sections, required this.notes});
}

/// Minutes Maker, Stage 5 — calls `generateMinutes` with a session's
/// captured page images to turn disordered handwritten notes into a
/// structured minutes document. Same hard-timeout-covers-everything
/// pattern as every other AI call in this app (see
/// HandwrittenListTranscriptionService's doc comment for the full
/// reasoning): nothing in [reconstruct] runs outside the timeout, so it
/// always either finishes or surfaces a clear, actionable error.
class MinutesReconstructionService {
  MinutesReconstructionService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<ReconstructedMinutes> reconstruct(List<File> pageFiles, {void Function(String status)? onProgress}) async {
    var lastStatus = 'starting';
    void track(String status) {
      lastStatus = status;
      onProgress?.call(status);
    }

    try {
      return await _run(pageFiles, track).timeout(
        const Duration(seconds: 100),
        onTimeout: () => throw MinutesReconstructionUnavailable(
          'This is taking too long and may be stuck (last step: "$lastStatus"). Check your mobile data/Wi-Fi '
          'signal and try again — if it keeps happening with a good connection, please report which step it '
          'names here.',
        ),
      );
    } on MinutesReconstructionUnavailable {
      rethrow;
    } catch (error) {
      throw MinutesReconstructionUnavailable('Could not generate minutes from these notes (last step: "$lastStatus"): $error');
    }
  }

  Future<ReconstructedMinutes> _run(List<File> pageFiles, void Function(String status)? onProgress) async {
    onProgress?.call('Checking connection…');
    if (!await isOnline) {
      throw const MinutesReconstructionUnavailable("You're offline. Connect to the internet to generate minutes.");
    }

    onProgress?.call('Signing in…');
    await AuthService.instance.ensureSignedIn();

    onProgress?.call('Preparing photos…');
    final callable = _functions.httpsCallable(
      'generateMinutes',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 95)),
    );

    Object? rawData;
    try {
      final images = [for (final f in pageFiles) base64Encode(await f.readAsBytes())];
      onProgress?.call('Reading and organizing your notes with AI…');
      final result = await callable.call<Object?>({'pageImagesBase64': images});
      rawData = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw MinutesReconstructionUnavailable(e.message ?? 'Failed to generate minutes from these notes.');
    }

    // Fully defensive, same discipline as HandwrittenListTranscriptionService
    // — `is` checks at every level rather than blind casts.
    if (rawData is! Map) {
      throw const MinutesReconstructionUnavailable('The minutes response was in an unexpected format.');
    }
    final data = rawData;

    final titleRaw = data['meetingTitle'];
    final meetingTitle = titleRaw is String && titleRaw.trim().isNotEmpty ? titleRaw.trim() : 'Meeting Minutes';

    final sectionsRaw = data['sections'];
    if (sectionsRaw is! List) {
      throw const MinutesReconstructionUnavailable('The minutes response was in an unexpected format.');
    }
    final sections = <MinutesSection>[
      for (final s in sectionsRaw)
        if (s is Map && s['heading'] is String && s['lines'] is List)
          MinutesSection(
            heading: s['heading'] as String,
            lines: (s['lines'] as List).whereType<String>().toList(),
          ),
    ];
    if (sections.isEmpty) {
      throw const MinutesReconstructionUnavailable('No usable content could be found in these notes.');
    }

    final notes = data['notes'];
    return ReconstructedMinutes(meetingTitle: meetingTitle, sections: sections, notes: notes is String ? notes : '');
  }
}
