import 'package:flutter/material.dart';

import '../widgets/pupil_ad_gate_dialog.dart';

/// Learner-side ad gate (added 2026-09-17, per explicit request):
/// "all available functions of the app from the learner facing side
/// will all be accessible by watching two 60 second video ads with the
/// exception of the act of joining a class." [PupilHomeScreen] wraps
/// every gated tile's tap with [ensureUnlocked]; "Join a Class" is the
/// one tile left completely unwrapped, since it's the action that
/// connects a pupil to their teacher in the first place and can't sit
/// behind anything.
///
/// Session-scoped, matching the same convention [EntitlementService]
/// already uses elsewhere in this app (`_adUnlockedThisSession`): watch
/// the 2 ads ONCE and every gated pupil function stays unlocked for the
/// rest of this app session, rather than re-requiring 2 fresh ads on
/// every single tap — a deliberate choice, not an oversight, since
/// per-tap gating would make the app nearly unusable for a pupil moving
/// between, say, Home Assignment and Test Submission in one sitting.
class PupilAdGateService {
  PupilAdGateService._internal();
  static final PupilAdGateService instance = PupilAdGateService._internal();

  bool _unlockedThisSession = false;

  bool get isUnlockedThisSession => _unlockedThisSession;

  /// Shows the 2-ad gate only if it hasn't already been watched this
  /// session; returns true if the caller should proceed (either already
  /// unlocked, or the ads were just watched to completion).
  Future<bool> ensureUnlocked(BuildContext context) async {
    if (_unlockedThisSession) return true;
    final watched = await showPupilTwoAdGate(context);
    if (watched) _unlockedThisSession = true;
    return watched;
  }
}
