import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A teacher's own name, school, and (most recently used) class name — the
/// three header details that never come from the syllabus/scheme of work
/// the way Subject/Topic do, so nothing else in the app can auto-fill them.
/// Persisted on-device (see [TeacherProfileRepository]) so a teacher only
/// ever types these once; every later lesson plan pre-fills them, still
/// fully editable per lesson (a teacher covering more than one class types
/// over the remembered class name for that specific lesson).
class TeacherProfile {
  final String name;
  final String school;
  final String className;

  const TeacherProfile({this.name = '', this.school = '', this.className = ''});

  bool get isEmpty => name.isEmpty && school.isEmpty && className.isEmpty;

  TeacherProfile copyWith({String? name, String? school, String? className}) => TeacherProfile(
        name: name ?? this.name,
        school: school ?? this.school,
        className: className ?? this.className,
      );

  Map<String, dynamic> toJson() => {'name': name, 'school': school, 'className': className};

  factory TeacherProfile.fromJson(Map<String, dynamic> json) => TeacherProfile(
        name: json['name'] as String? ?? '',
        school: json['school'] as String? ?? '',
        className: json['className'] as String? ?? '',
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
