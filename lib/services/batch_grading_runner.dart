import '../models/marking_credits.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import 'marking_credits_service.dart';
import 'marking_entitlement_service.dart';
import 'marking_grading_service.dart';
import 'marking_script_repository.dart';

/// Grades a batch of scripts against one scheme, sequentially (never in
/// parallel — keeps progress reporting honest and avoids bursting the AI
/// provider). Shared by MarkingQueueScreen's own "Process" button and the
/// new continuous batch-capture flow's "Mark all scripts?" confirmation,
/// so both go through identical retry/credit/persistence behavior
/// rather than two copies drifting apart.
///
/// A failure retries once immediately; if that also fails the script is
/// left as [MarkingScriptStatus.needsRetry] with the error recorded, and
/// the rest of the batch keeps going rather than stopping cold.
///
/// CREDITS (Monetization, 2026-09-19): the server charges a script only
/// after a valid result exists, and only once — both attempts (and any later
/// tap on "retry") carry the SAME request id, so a script the server already
/// charged is never charged again. "Not enough credits" is not a failure to
/// retry: the script goes back to the queue untouched, and the batch stops
/// ([onOutOfCredits]) with everything already marked kept.
///
/// [onProgress] fires after each script (processed count, total, current
/// script) so a caller can update its own UI; [onOutOfCredits] fires at most
/// once, only if the batch stops early for that reason — its argument is the
/// server's refusal (with the exact shortfall), or null when the app's own
/// courtesy check stopped it before asking.
/// [onScriptGraded] fires once per script immediately after AI grading
/// finishes (success or a final failure after the one retry above) — the
/// hook for a "score just came in" UI moment (e.g. MarkingQueueScreen's
/// pop-and-fade score animation), distinct from [onProgress] which only
/// carries counts, not which script or how it went.
Future<void> runBatchGrading({
  required List<MarkingScript> scripts,
  required MarkingScheme scheme,
  required MarkingScriptRepository repository,
  required MarkingGradingService gradingService,
  void Function(int done, int total)? onProgress,
  void Function(InsufficientCreditsException? reason)? onOutOfCredits,
  void Function(MarkingScript graded)? onScriptGraded,
}) async {
  var done = 0;
  for (final script in scripts) {
    // Scheme-based marking always carries a key, so it bills as Key-based.
    if (!await MarkingEntitlementService.instance.canGradeAnother(
      engine: MarkingEngineKind.keyed,
      pages: script.pageFileNames.length,
    )) {
      onOutOfCredits?.call(null);
      break;
    }

    await repository.update(script.copyWith(status: MarkingScriptStatus.processing));

    final requestKey = 'script:${script.id}';
    final requestId = MarkingRequestIds.forKey(requestKey);

    Future<MarkingScript> attempt() async {
      final pageFiles = await repository.pageFilesFor(script);
      final graded = await gradingService.grade(
        pageFiles: pageFiles,
        scheme: scheme,
        preSegmentedAnswers: script.preSegmentedAnswers,
        subjectName: script.subjectName,
        requestId: requestId,
      );
      return script.copyWith(
        status: MarkingScriptStatus.graded,
        gradedAnswers: graded.answers,
        observations: graded.observations,
        clearLastError: true,
      );
    }

    MarkingScript result;
    try {
      try {
        result = await attempt();
      } on InsufficientCreditsException {
        rethrow; // never retry a refusal — nothing was charged, and asking again changes nothing
      } catch (firstError) {
        result = await attempt();
      }
      MarkingRequestIds.clear(requestKey); // marked and charged — the next marking of this script is a new action
    } on InsufficientCreditsException catch (e) {
      // Put the script back exactly as it was — this is not a failure of the script.
      await repository.update(script);
      onOutOfCredits?.call(e);
      break;
    } catch (secondError) {
      result = script.copyWith(status: MarkingScriptStatus.needsRetry, lastError: secondError.toString());
    }

    await repository.update(result);
    done++;
    onScriptGraded?.call(result);
    onProgress?.call(done, scripts.length);
  }
}
