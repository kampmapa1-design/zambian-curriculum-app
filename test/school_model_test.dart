import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/school.dart';

/// School Network + Timetable Generation + subscription-tier logic — real
/// regression coverage for the parts of school.dart that had no
/// automated test: the backward-compatible subscriptionTier fallback (a
/// real, easy-to-get-backwards migration), and canManageTimetable's
/// three-way OR (leadership / administrator / Timetable Operator).
void main() {
  group('SubscriptionTier ordering', () {
    test('basic < gold < institutional, by .index', () {
      expect(SubscriptionTier.basic.index, lessThan(SubscriptionTier.gold.index));
      expect(SubscriptionTier.gold.index, lessThan(SubscriptionTier.institutional.index));
    });

    test('fromWire round-trips every real value', () {
      for (final tier in SubscriptionTier.values) {
        expect(SubscriptionTier.fromWire(tier.wireValue), tier);
      }
    });

    test('fromWire defaults to basic for null/unknown values', () {
      expect(SubscriptionTier.fromWire(null), SubscriptionTier.basic);
      expect(SubscriptionTier.fromWire('platinum'), SubscriptionTier.basic);
    });
  });

  group('School.fromMap subscriptionTier backward compatibility', () {
    test('a school with subscriptionTier set uses it directly', () {
      final school = School.fromMap('s1', {
        'name': 'Test School',
        'institutionalSubscription': false,
        'subscriptionTier': 'gold',
      });
      expect(school.subscriptionTier, SubscriptionTier.gold);
      expect(school.hasTimetableAccess, isTrue);
    });

    test('a school with NO subscriptionTier field but institutionalSubscription: true is treated as institutional (real migration case)', () {
      final school = School.fromMap('s1', {
        'name': 'Legacy School',
        'institutionalSubscription': true,
      });
      expect(school.subscriptionTier, SubscriptionTier.institutional);
      expect(school.hasTimetableAccess, isTrue, reason: 'an already-paying school must not lose Gold-gated access just because this field is new');
    });

    test('a school with neither field defaults to basic (no timetable access)', () {
      final school = School.fromMap('s1', {'name': 'New School'});
      expect(school.subscriptionTier, SubscriptionTier.basic);
      expect(school.hasTimetableAccess, isFalse);
    });

    test('hasTimetableAccess is false for basic, true for gold and institutional', () {
      expect(_schoolWithTier(SubscriptionTier.basic).hasTimetableAccess, isFalse);
      expect(_schoolWithTier(SubscriptionTier.gold).hasTimetableAccess, isTrue);
      expect(_schoolWithTier(SubscriptionTier.institutional).hasTimetableAccess, isTrue);
    });
  });

  group('canManageTimetable', () {
    test('head teacher and deputy can manage', () {
      expect(canManageTimetable(SchoolRole.headTeacher, false), isTrue);
      expect(canManageTimetable(SchoolRole.deputy, false), isTrue);
    });

    test('administrator can manage', () {
      expect(canManageTimetable(SchoolRole.administrator, false), isTrue);
    });

    test('a plain teacher cannot manage, UNLESS co-opted as a Timetable Operator', () {
      expect(canManageTimetable(SchoolRole.teacher, false), isFalse);
      expect(canManageTimetable(SchoolRole.teacher, true), isTrue);
    });

    test('grade teacher and observer cannot manage without the operator flag', () {
      expect(canManageTimetable(SchoolRole.gradeTeacher, false), isFalse);
      expect(canManageTimetable(SchoolRole.observer, false), isFalse);
    });

    test('a null role (not yet loaded) cannot manage unless the operator flag is set', () {
      expect(canManageTimetable(null, false), isFalse);
      expect(canManageTimetable(null, true), isTrue);
    });
  });

  group('SchoolRole.isLeadership', () {
    test('only head teacher and deputy count as leadership — administrator does NOT (checked separately everywhere)', () {
      expect(SchoolRole.headTeacher.isLeadership, isTrue);
      expect(SchoolRole.deputy.isLeadership, isTrue);
      expect(SchoolRole.administrator.isLeadership, isFalse);
      expect(SchoolRole.teacher.isLeadership, isFalse);
      expect(SchoolRole.gradeTeacher.isLeadership, isFalse);
      expect(SchoolRole.observer.isLeadership, isFalse);
    });
  });

  group('SchoolClass.learnerUids backward compatibility', () {
    test('a class with no learnerUids field parses to an empty map, not a crash', () {
      final schoolClass = SchoolClass.fromMap('c1', {
        'classGrade': 'Grade 8A',
        'learnerNames': ['Chanda Mwape'],
      });
      expect(schoolClass.learnerUids, isEmpty);
    });

    test('a class with learnerUids parses the name->uid map correctly', () {
      final schoolClass = SchoolClass.fromMap('c1', {
        'classGrade': 'Grade 8A',
        'learnerNames': ['Chanda Mwape'],
        'learnerUids': {'Chanda Mwape': 'pupil-uid-1'},
      });
      expect(schoolClass.learnerUids['Chanda Mwape'], 'pupil-uid-1');
    });
  });
}

School _schoolWithTier(SubscriptionTier tier) => School(
      id: 's1',
      name: 'Test',
      province: '',
      district: '',
      headTeacherName: '',
      code: 'ABC123',
      institutionalSubscription: false,
      subscriptionTier: tier,
    );
