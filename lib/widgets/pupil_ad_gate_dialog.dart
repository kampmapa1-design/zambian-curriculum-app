import 'package:flutter/material.dart';

import '../services/rewarded_ad_service.dart';

/// Learner-side ad gate (generalized 2026-09-17 from what was originally
/// a Home Assignment-submission-only dialog, added 2026-09-14 — "require
/// watching 2 consecutive uninterrupted 60-second video ads." Per
/// explicit request, this now gates every pupil-facing function, not
/// just Home Assignment submission — see `PupilAdGateService`, which
/// wraps this dialog with session-wide unlock tracking so it's only
/// ever shown once per app session, not once per screen). Reuses
/// [RewardedAdService.showAds] exactly (the same `count:` primitive
/// `MinutesProcessingScreen` already uses for its own 4-ad gate), so no
/// new ad-sequencing logic exists here — only the UI + the
/// watched-to-completion check.
///
/// Real, disclosed limitation: `RewardedAdService` is currently a stub
/// (google_mobile_ads was removed 2026-08-30 after crashing on a real
/// device — see that service's own doc comment) — `showAds()` always
/// returns `true` instantly without actually playing anything. This
/// gate is built and wired for real so nothing about the FLOW needs to
/// change once a working ad SDK is re-integrated; only
/// `RewardedAdService`'s internals need to change, not any caller of
/// this function.
///
/// Returns `true` only if both ads were watched to completion — a
/// caller should treat any other result as "access blocked" and NOT
/// proceed.
Future<bool> showPupilTwoAdGate(BuildContext context) async {
  const totalAds = 2;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => const _AdGateDialog(totalAds: totalAds),
  );
  return result ?? false;
}

class _AdGateDialog extends StatefulWidget {
  const _AdGateDialog({required this.totalAds});
  final int totalAds;

  @override
  State<_AdGateDialog> createState() => _AdGateDialogState();
}

class _AdGateDialogState extends State<_AdGateDialog> {
  int _completed = 0;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() => _started = true);
    final watched = await RewardedAdService.instance.showAds(
      count: widget.totalAds,
      onProgress: (completed, total) {
        if (!mounted) return;
        setState(() => _completed = completed);
      },
    );
    if (!mounted) return;
    if (!watched) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("The ads weren't watched to completion, so this stays locked. Try again without interruption.")),
      );
    }
    Navigator.of(context).pop(watched);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Watch to unlock'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Watch $_completed of ${widget.totalAds} short ads, one after another, to unlock this.'),
          const SizedBox(height: 20),
          _started ? LinearProgressIndicator(value: _completed / widget.totalAds) : const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
