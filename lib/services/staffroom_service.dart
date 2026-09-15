import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/school.dart';

/// Stage 10 of School Network (added 2026-09-13) — client side of the
/// Staffroom. Unlike the rest of School Network, this writes to Firestore
/// directly (see firestore.rules for why that's safe here); no Cloud
/// Function involved.
class StaffroomService {
  StaffroomService({FirebaseFirestore? firestore}) : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _postsRef(String schoolId) =>
      _firestore.collection('schools').doc(schoolId).collection('staffroom');

  Stream<List<StaffroomPost>> watchPosts(String schoolId, {String? topic}) {
    Query<Map<String, dynamic>> query = _postsRef(schoolId).orderBy('createdAt', descending: true);
    if (topic != null) query = query.where('topic', isEqualTo: topic);
    return query.snapshots().map((snap) {
      final posts = snap.docs.map((d) => StaffroomPost.fromMap(d.id, d.data())).toList();
      // Pinned posts always float to the top, newest-pinned first, then
      // everything else newest-first (already the query's own order).
      posts.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return 0; // stable sort preserves the query's createdAt ordering within each group
      });
      return posts;
    });
  }

  Future<void> post({required String schoolId, required String text, required String topic, required String authorName}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _postsRef(schoolId).add({
      'authorUid': uid,
      'authorName': authorName,
      'text': text.trim(),
      'topic': topic.trim().isEmpty ? 'General' : topic.trim(),
      'pinned': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> setPinned(String schoolId, String postId, bool pinned) => _postsRef(schoolId).doc(postId).update({'pinned': pinned});

  /// Timetable Generation, Stage 13 — "Pin to Staffroom" straight from a
  /// timetable view. Two writes because the rules require it (see
  /// firestore.rules: create must always start `pinned: false`, only an
  /// immediately-following update by leadership/administrator may flip
  /// it true) — same two-step a moderator's own Pin button already does,
  /// just chained together here since the caller wants it pinned from
  /// the start, not pinned-after-the-fact. A non-leadership caller's
  /// second write is rejected by the rules (not this method), leaving a
  /// normal unpinned post behind rather than nothing at all.
  Future<void> postPinned({required String schoolId, required String text, required String topic, required String authorName}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final ref = await _postsRef(schoolId).add({
      'authorUid': uid,
      'authorName': authorName,
      'text': text.trim(),
      'topic': topic.trim().isEmpty ? 'General' : topic.trim(),
      'pinned': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await ref.update({'pinned': true});
  }

  Future<void> deletePost(String schoolId, String postId) => _postsRef(schoolId).doc(postId).delete();
}
