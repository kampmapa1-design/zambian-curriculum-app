import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

/// Safeguard added 2026-09-28, after a real multi-day incident: a native
/// Firebase SDK failure (see `AuthService`'s own doc comment for the full
/// story — a broken Crashlytics component registration was taking down
/// `Firebase.initializeApp()` itself) went unnoticed for days because
/// nothing ever announced it — a teacher only discovered it piecemeal, one
/// broken feature at a time, across separate sessions, each looking like
/// an unrelated bug. This card surfaces the SAME underlying fact (no
/// Firebase app registered — see [Firebase.apps]) the moment the home
/// screen loads, in plain language, instead of leaving it to be discovered
/// by trial and error. Renders nothing once Firebase is actually up.
///
/// Deliberately a `StatelessWidget`, not a stream/timer-driven one: by the
/// time any screen in this app can build, `main.dart`'s own cold-start
/// attempt has already fully finished (success or failure) — `Firebase.apps`
/// is already in its settled state for the rest of the process, except for
/// the rare case where some other screen's lazy retry (`AuthService`)
/// succeeds later; re-checking fresh on every rebuild (e.g. navigating back
/// to the home screen) is simple and catches that case too, with no extra
/// machinery needed.
class FirebaseUnavailableBanner extends StatelessWidget {
  const FirebaseUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (Firebase.apps.isNotEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.cloud_off_outlined, color: colorScheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Online features aren't reachable right now — Chief Marker, Teaching Notes, "
                "downloads, and anything else needing the internet won't work until this clears. "
                "Everything offline still works normally. Try fully closing and reopening the app.",
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
