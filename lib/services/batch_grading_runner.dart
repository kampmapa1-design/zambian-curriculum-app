import '../models/marking_scheme.dart';
import '../models/marking_script.dart';
import 'marking_entitlement_service.dart';
import 'marking_grading_service.dart';
import 'marking_script_repository.dart';

/// Grades a batch of scripts against one scheme, sequentially (never in
/// parallel — keeps progress reporting honest and avoids bursting the AI
/// provider). Shared by MarkingQueueScreen's own "Process" button and the
/// new continuous batch-capture flow's "Mark all scripts?" confirmation,
/// so both go through identical retry/entitlement/persistence behavior
/// rather than two copies drifting apart.
///
/// A failure retries once immediately; if that also fails the script is
/// left as [MarkingScriptStatus.needsRetry] with the error recorded, and
/// the rest of the batch keeps going rather than stopping cold. Stage 9's
/// entitlement check runs per script, not once for the whole batch — a
/// teacher partway through their free allowance gets as many scripts
/// graded as they have left, then the rest stay queued.
///
/// [onProgress] fires after each script (processed count, total, current
/// script) so a caller can update its own UI; [onOutOfFreeGradings] fires
/// at most once, only if the batch stops early for that reason.
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
  void Function()? onOutOfFreeGradings,
  void Function(MarkingScript graded)? onScriptGraded,
}) async {
  var done = 0;
  for (final script in scripts) {
    if (!await MarkingEntitlementService.instance.canGradeAnother()) {
      onOutOfFreeGradings?.call();
      break;
    }

    await repository.update(script.copyWith(status: MarkingScriptStatus.processing));

    MarkingScript result;
    try {
      final pageFiles = await repository.pageFilesFor(script);
      final graded = await gradingService.grade(pageFiles: pageFiles, scheme: scheme);
      result = script.copyWith(
        status: MarkingScriptStatus.graded,
        gradedAnswers: graded.answers,
        observations: graded.observations,
        clearLastError: true,
      );
      await MarkingEntitlementService.instance.recordGradingUsed();
    } catch (firstError) {
      try {
        final pageFiles = await repository.pageFilesFor(script);
        final graded = await gradingService.grade(pageFiles: pageFiles, scheme: scheme);
        result = script.copyWith(
          status: MarkingScriptStatus.graded,
          gradedAnswers: graded.answers,
          observations: graded.observations,
          clearLastError: true,
        );
        await MarkingEntitlementService.instance.recordGradingUsed();
      } catch (secondError) {
        result = script.copyWith(status: MarkingScriptStatus.needsRetry, lastError: secondError.toString());
      }
    }

    await repository.update(result);
    done++;
    onScriptGraded?.call(result);
    onProgress?.call(done, scripts.length);
  }
}
