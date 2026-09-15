import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/teacher_profile_repository.dart';

/// Regression coverage for the Home Assignment epic's Stage 1 addition
/// (2026-09-14) — [AccountRole] on [TeacherProfile]. Real risk this
/// guards against: a profile saved before `role` existed, or with a
/// corrupted/unexpected `role` string, must never crash `fromJson` — it
/// should just come back as "not yet chosen" (null), which is exactly
/// what gates FirstLaunchScreen.
void main() {
  group('AccountRole', () {
    test('wireValue/fromWire round-trip for every value', () {
      for (final role in AccountRole.values) {
        expect(AccountRole.fromWire(role.wireValue), role);
      }
    });

    test('fromWire returns null for unknown/missing values, never throws', () {
      expect(AccountRole.fromWire(null), isNull);
      expect(AccountRole.fromWire(''), isNull);
      expect(AccountRole.fromWire('parent'), isNull);
      expect(AccountRole.fromWire('TEACHER'), isNull); // case-sensitive by design — wire values are always lowercase
    });
  });

  group('TeacherProfile JSON round-trip', () {
    test('role survives toJson/fromJson', () {
      const profile = TeacherProfile(name: 'Mrs Banda', role: AccountRole.pupil);
      final restored = TeacherProfile.fromJson(profile.toJson());
      expect(restored.role, AccountRole.pupil);
      expect(restored.name, 'Mrs Banda');
    });

    test('a profile with no role key at all (pre-Stage-1 data) parses with role: null, not a crash', () {
      final restored = TeacherProfile.fromJson({'name': 'Mr Phiri', 'school': 'Kabulonga Girls'});
      expect(restored.role, isNull);
      expect(restored.name, 'Mr Phiri');
    });

    test('toJson omits the role key entirely when role is unset (keeps old payload shape)', () {
      const profile = TeacherProfile(name: 'Anonymous Teacher');
      expect(profile.toJson().containsKey('role'), isFalse);
    });

    test('copyWith(role:) only changes role, leaves every other field untouched', () {
      const profile = TeacherProfile(name: 'Mrs Zulu', school: 'St Mary\'s', phone: '+260977000000');
      final updated = profile.copyWith(role: AccountRole.teacher);
      expect(updated.role, AccountRole.teacher);
      expect(updated.name, profile.name);
      expect(updated.school, profile.school);
      expect(updated.phone, profile.phone);
    });
  });
}
