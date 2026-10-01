import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/school.dart';
import 'package:zambian_curriculum_app/models/web_dashboard_access.dart';

const _admins = [SchoolRole.headTeacher, SchoolRole.deputy, SchoolRole.administrator];
const _others = [SchoolRole.teacher, SchoolRole.gradeTeacher, SchoolRole.observer];

WebDashboardAccess _access(SchoolRole? role, {bool operator = false, bool institutional = false}) =>
    webDashboardAccess(role: role, isTimetableOperator: operator, institutionalSchool: institutional);

List<WebDashboardSection> _sections(
  WebDashboardAccess access, {
  SchoolRole? role = SchoolRole.headTeacher,
  bool institutional = false,
  bool gold = true,
  bool owner = false,
}) =>
    webDashboardSections(access: access, role: role, institutionalSchool: institutional, hasTimetableAccess: gold, isOwner: owner);

void main() {
  group('who may use the dashboard', () {
    test('the three administrators (Head Teacher, Deputy, Administrator) at an INSTITUTIONAL school get everything', () {
      for (final r in _admins) {
        expect(_access(r, institutional: true), WebDashboardAccess.full, reason: '$r');
      }
    });

    test('the three administrators at any OTHER school are limited to timetable creation', () {
      for (final r in _admins) {
        expect(_access(r), WebDashboardAccess.timetableOnly, reason: '$r');
      }
    });

    test('the timetable operator gets timetable creation only - even at an institutional school', () {
      for (final inst in [false, true]) {
        for (final r in [..._others, null]) {
          expect(_access(r, operator: true, institutional: inst), WebDashboardAccess.timetableOnly, reason: '$r inst=$inst');
        }
      }
    });

    test('ordinary teachers, grade teachers, observers and non-members are NOT let in, subscribed or not', () {
      for (final inst in [false, true]) {
        for (final r in [..._others, null]) {
          expect(_access(r, institutional: inst), WebDashboardAccess.none, reason: '$r inst=$inst');
        }
      }
    });

    test('an administrator who is also the timetable operator is still just an administrator', () {
      expect(_access(SchoolRole.deputy, operator: true, institutional: true), WebDashboardAccess.full);
      expect(_access(SchoolRole.deputy, operator: true), WebDashboardAccess.timetableOnly);
    });
  });

  group('what the sidebar offers', () {
    test('FULL access at an institutional Gold+ school: every section, including Broadcast to Guardians', () {
      final s = _sections(WebDashboardAccess.full, institutional: true);
      expect(s, [
        WebDashboardSection.dashboard,
        WebDashboardSection.reportFormStatus,
        WebDashboardSection.timetable,
        WebDashboardSection.timetableConstraints,
        WebDashboardSection.generatedTimetable,
        WebDashboardSection.timetableByTeacher,
        WebDashboardSection.staff,
        WebDashboardSection.staffroom,
        WebDashboardSection.broadcast,
      ]);
    });

    test('TIMETABLE-ONLY at a Gold school: just Setup, Constraints and Generated - nothing else, in particular no staff, staffroom, class board or broadcast', () {
      final s = _sections(WebDashboardAccess.timetableOnly);
      expect(s, [WebDashboardSection.timetable, WebDashboardSection.timetableConstraints, WebDashboardSection.generatedTimetable]);
      for (final banned in [
        WebDashboardSection.dashboard,
        WebDashboardSection.reportFormStatus,
        WebDashboardSection.timetableByTeacher,
        WebDashboardSection.staff,
        WebDashboardSection.staffroom,
        WebDashboardSection.broadcast,
        WebDashboardSection.ownerFinance,
      ]) {
        expect(s, isNot(contains(banned)), reason: '$banned');
      }
    });

    test('a Basic school (no timetable plan): no sections at all, and the screen shows the upgrade notice', () {
      expect(_sections(WebDashboardAccess.timetableOnly, gold: false), isEmpty);
      expect(showTimetableUpgradeNotice(access: WebDashboardAccess.timetableOnly, hasTimetableAccess: false), isTrue);
      expect(showTimetableUpgradeNotice(access: WebDashboardAccess.timetableOnly, hasTimetableAccess: true), isFalse);
    });

    test('Broadcast is only for an administrator at an INSTITUTIONAL school', () {
      expect(_sections(WebDashboardAccess.full, institutional: false), isNot(contains(WebDashboardSection.broadcast)));
      expect(_sections(WebDashboardAccess.full, institutional: true, role: SchoolRole.administrator), contains(WebDashboardSection.broadcast));
    });

    test('nobody without access sees a school section, and no upgrade notice is shown to them', () {
      expect(_sections(WebDashboardAccess.none, role: SchoolRole.teacher), isEmpty);
      expect(showTimetableUpgradeNotice(access: WebDashboardAccess.none, hasTimetableAccess: false), isFalse);
    });

    test('the OWNER always gets Owner finance - even as an ordinary teacher, or with no school at all - and only the owner', () {
      expect(_sections(WebDashboardAccess.none, role: SchoolRole.teacher, owner: true), [WebDashboardSection.ownerFinance]);
      expect(_sections(WebDashboardAccess.none, role: null, owner: true), [WebDashboardSection.ownerFinance]);
      expect(_sections(WebDashboardAccess.timetableOnly, owner: true).last, WebDashboardSection.ownerFinance);
      for (final a in WebDashboardAccess.values) {
        expect(_sections(a, owner: false), isNot(contains(WebDashboardSection.ownerFinance)));
      }
    });
  });
}
