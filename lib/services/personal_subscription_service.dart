import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/school.dart';
import 'auth_service.dart';

/// Individual-teacher subscriptions (owner decision, 2026-09-28): a
/// teacher's own personal tier, read from `personalSubscriptions/{uid}` —
/// set manually via Firebase Console for now, same as `School.subscriptionTier`
/// itself (a real self-serve purchase path is a separate, later piece of
/// work that would write into this same document). Mirrors the server's own
/// `meetsTimetableTier` OR-logic in index.ts: a client-side Gold+ gate must
/// check BOTH the school's tier and this, or a subscribed individual teacher
/// would see a locked screen the server would actually let them use.
class PersonalSubscriptionService {
  PersonalSubscriptionService({FirebaseFirestore? firestore}) : _firestoreOverride = firestore;

  final FirebaseFirestore? _firestoreOverride;
  FirebaseFirestore get _firestore => _firestoreOverride ?? FirebaseFirestore.instance;

  /// [SubscriptionTier.basic] (never gates anything on its own) for a
  /// teacher with no personal subscription doc, when signed in anonymously,
  /// or on any read failure (offline/rules) — the school's own tier, if
  /// any, still applies untouched; this only ever adds access, never removes it.
  Future<SubscriptionTier> fetchTier() async {
    try {
      final uid = (await AuthService.instance.ensureSignedIn()).uid;
      final snap = await _firestore.doc('personalSubscriptions/$uid').get();
      if (!snap.exists) return SubscriptionTier.basic;
      return SubscriptionTier.fromWire(snap.data()?['tier'] as String?);
    } catch (_) {
      return SubscriptionTier.basic;
    }
  }
}
