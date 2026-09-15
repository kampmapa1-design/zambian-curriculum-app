import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Which kind of account this is — added 2026-09-14 for the first-launch
/// capture flow (see FirstLaunchScreen). `null` on [TeacherProfile.role]
/// means "not yet chosen," which is exactly what gates that screen: every
/// account created before this field existed is also `null` and sees the
/// capture flow once, same as a brand-new install.
enum AccountRole {
  teacher,
  pupil;

  String get wireValue => name;

  static AccountRole? fromWire(String? value) => switch (value) {
        'teacher' => AccountRole.teacher,
        'pupil' => AccountRole.pupil,
        _ => null,
      };
}

/// A teacher's own name, school, and (most recently used) class name — the
/// three header details that never come from the syllabus/scheme of work
/// the way Subject/Topic do, so nothing else in the app can auto-fill them.
/// Persisted on-device (see [TeacherProfileRepository]) so a teacher only
/// ever types these once; every later lesson plan pre-fills them, still
/// fully editable per lesson (a teacher covering more than one class types
/// over the remembered class name for that specific lesson).
///
/// [loginMethod]/[phone]/[email] were added 2026-09-13 alongside real
/// phone/email sign-in (see TeacherAuthService) — 'anonymous' is still the
/// default for every teacher who hasn't signed up. These three are the
/// identity the future School Code and Staffroom features attach to; they
/// have no bearing on the name/school/className fields above, which existed
/// long before real accounts did and keep working the same for teachers who
/// never sign up at all.
class TeacherProfile {
  final String name;
  final String school;
  final String className;
  final String loginMethod; // 'anonymous' | 'phone' | 'email'
  final String phone;
  final String email;

  /// Added 2026-09-14 — see [AccountRole]. Null until the first-launch
  /// capture flow (or an existing account's own one-time prompt) sets it.
  final AccountRole? role;

  const TeacherProfile({
    this.name = '',
    this.school = '',
    this.className = '',
    this.loginMethod = 'anonymous',
    this.phone = '',
    this.email = '',
    this.role,
  });

  bool get isEmpty => name.isEmpty && school.isEmpty && className.isEmpty;

  TeacherProfile copyWith({
    String? name,
    String? school,
    String? className,
    String? loginMethod,
    String? phone,
    String? email,
    AccountRole? role,
  }) =>
      TeacherProfile(
        name: name ?? this.name,
        school: school ?? this.school,
        className: className ?? this.className,
        loginMethod: loginMethod ?? this.loginMethod,
        phone: phone ?? this.phone,
        email: email ?? this.email,
        role: role ?? this.role,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'school': school,
        'className': className,
        'loginMethod': loginMethod,
        'phone': phone,
        'email': email,
        if (role != null) 'role': role!.wireValue,
      };

  factory TeacherProfile.fromJson(Map<String, dynamic> json) => TeacherProfile(
        name: json['name'] as String? ?? '',
        school: json['school'] as String? ?? '',
        className: json['className'] as String? ?? '',
        loginMethod: json['loginMethod'] as String? ?? 'anonymous',
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: AccountRole.fromWire(json['role'] as String?),
      );
}

/// On-device storage for [TeacherProfile] — one profile for the whole app
/// (this is a single-teacher device, same assumption every other per-device
/// setting in this app already makes), via shared_preferences, same
/// pattern as [LessonCheckpointRepository].
class TeacherProfileRepository {
  static const _key = 'teacher_profile';

  Future<TeacherProfile> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const TeacherProfile();
    try {
      return TeacherProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const TeacherProfile();
    }
  }

  Future<void> save(TeacherProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(profile.toJson()));
  }
}
