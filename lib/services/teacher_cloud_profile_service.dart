import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'teacher_auth_service.dart';
import 'teacher_profile_repository.dart';

/// Mirrors a signed-up teacher's profile to `teacher_profiles/{uid}` in
/// Firestore (Stage 5, added 2026-09-13) — the one record the not-yet-built
/// School Code and Staffroom features will look a teacher up by. Deliberately
/// separate from [TeacherProfileRepository]'s on-device copy, which stays the
/// source of truth for the name/school/className fields every other screen
/// in the app already reads today: this only exists once a teacher has a
/// real UID worth other people/devices finding, so it's a best-effort mirror,
/// never a dependency of any existing offline feature. A teacher who never
/// signs up (still anonymous) never gets a document here at all.
class TeacherCloudProfileService {
  TeacherCloudProfileService({FirebaseFirestore? firestore}) : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Call right after a successful sign-up/sign-in. Safe to call repeatedly
  /// (e.g. every app start) — it's a merge, not a replace, so it never wipes
  /// fields a future School Code/Staffroom feature adds to the same document.
  Future<void> syncFromAuth(User user, TeacherProfile profile) async {
    if (user.isAnonymous) return;
    final method = loginMethodOf(user);
    await _firestore.collection('teacher_profiles').doc(user.uid).set({
      'name': profile.name,
      'school': profile.school,
      'loginMethod': method.name,
      if (method == TeacherLoginMethod.phone) 'phone': user.phoneNumber ?? profile.phone,
      if (method == TeacherLoginMethod.email) 'email': user.email ?? profile.email,
      if (profile.role != null) 'role': profile.role!.wireValue,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
