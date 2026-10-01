import 'school.dart';

/// Who may use the web admin dashboard, and what they see there.
///
/// The rules (owner's decision, 2026-09-19):
///  * The dashboard is for the three ADMINISTRATORS - Head Teacher, Deputy and
///    Administrator - and for the appointed TIMETABLE OPERATOR. Ordinary
///    teachers, grade teachers and observers are not let in (they use the phone
///    app). The app OWNER additionally sees the Owner finance section, whatever
///    their school role.
///  * At a school with the INSTITUTIONAL subscription the administrators get the
///    whole dashboard.
///  * At every other school the dashboard is limited to timetable creation, for
///    any of the three administrators or the timetable operator. (Timetable
///    creation itself still needs a Gold plan or higher - that gate is enforced
///    on the server and is unchanged - so a Basic school sees a notice instead.)
///
/// This decides what the SCREEN offers. It is a usability boundary, not the
/// security one: the Cloud Functions behind each action check the caller's role
/// and the school's plan themselves.
enum WebDashboardAccess {
  /// Not permitted to use the dashboard.
  none,

  /// Timetable creation only.
  timetableOnly,

  /// Everything.
  full,
}

enum WebDashboardSection {
  dashboard,
  reportFormStatus,
  timetable,
  timetableConstraints,
  generatedTimetable,
  timetableByTeacher,
  staff,
  staffroom,
  broadcast,
  ownerFinance,
}

/// One of the three administrators: Head Teacher, Deputy or Administrator.
bool isSchoolAdministrator(SchoolRole? role) =>
    role?.isLeadership == true || role == SchoolRole.administrator;

WebDashboardAccess webDashboardAccess({
  required SchoolRole? role,
  required bool isTimetableOperator,
  required bool institutionalSchool,
}) {
  final admin = isSchoolAdministrator(role);
  if (admin && institutionalSchool) return WebDashboardAccess.full;
  if (admin || isTimetableOperator) return WebDashboardAccess.timetableOnly;
  return WebDashboardAccess.none;
}

const _timetableSections = [
  WebDashboardSection.timetable,
  WebDashboardSection.timetableConstraints,
  WebDashboardSection.generatedTimetable,
];

/// The sidebar sections available, in display order. [hasTimetableAccess] is
/// the school's plan (Gold or higher); without it the timetable sections are
/// omitted and the screen shows a notice instead.
List<WebDashboardSection> webDashboardSections({
  required WebDashboardAccess access,
  required SchoolRole? role,
  required bool institutionalSchool,
  required bool hasTimetableAccess,
  required bool isOwner,
}) {
  final out = <WebDashboardSection>[];
  switch (access) {
    case WebDashboardAccess.full:
      out.add(WebDashboardSection.dashboard);
      out.add(WebDashboardSection.reportFormStatus);
      if (hasTimetableAccess) out.addAll(_timetableSections);
      out.addAll([WebDashboardSection.timetableByTeacher, WebDashboardSection.staff, WebDashboardSection.staffroom]);
      if (institutionalSchool && isSchoolAdministrator(role)) out.add(WebDashboardSection.broadcast);
    case WebDashboardAccess.timetableOnly:
      if (hasTimetableAccess) out.addAll(_timetableSections);
    case WebDashboardAccess.none:
      break;
  }
  if (isOwner) out.add(WebDashboardSection.ownerFinance);
  return out;
}

/// True when the person may manage timetables but their school's plan doesn't
/// include it - the screen then explains that instead of showing nothing.
bool showTimetableUpgradeNotice({required WebDashboardAccess access, required bool hasTimetableAccess}) =>
    access != WebDashboardAccess.none && !hasTimetableAccess;

/// Whether a school has the INSTITUTIONAL subscription (the newer tier field, or
/// the older boolean that predates it).
bool schoolIsInstitutional(School school) =>
    school.subscriptionTier == SubscriptionTier.institutional || school.institutionalSubscription;
