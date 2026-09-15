// Reusable fake-authenticated-context builders for the firestore.rules
// test suite, formalizing the inline staff()/pupil()/anon()/rando()
// helpers the original firestore.rules.test.mjs started with.
//
// Every builder takes `testEnv` as its first argument rather than closing
// over a module-level variable, since testEnv is created in each test
// file's own before() — this module has no state of its own.
//
// Two claim namespaces exist in firestore.rules and must never be
// confused: staff tokens carry schoolId/schoolRole, pupil tokens carry
// pupilSchoolId/pupilClassId. A context here only ever gets the claims
// its name promises — never both — matching how the real Cloud
// Functions never stamp both claim sets onto the same account.

/** The 6 real `schoolRole` values — see lib/models/school.dart. There is
 * no `timetable_operator` role; "Timetable Operator" is a separate
 * boolean field on a member document, not a schoolRole, and has no
 * presence in firestore.rules. */
export const SCHOOL_ROLES = [
  'teacher',
  'grade_teacher',
  'head_teacher',
  'deputy',
  'administrator',
  'observer',
];

/** The 3 roles firestore.rules treats as "leadership" (guardianContacts
 * read, staffroom pin/unpin, staffroom moderate-anyone's-post). */
export const LEADERSHIP_ROLES = ['head_teacher', 'deputy', 'administrator'];

/** A school staff member: schoolId/schoolRole custom claims, stamped in
 * reality only by registerSchool/joinSchoolByCode/updateSchoolMemberRole
 * (Cloud Functions, Admin SDK). `schoolRole` should be one of
 * SCHOOL_ROLES, but callers may pass anything to test rule behavior
 * against an unexpected value. */
export function staffContext(testEnv, uid, schoolId, schoolRole) {
  return testEnv.authenticatedContext(uid, { schoolId, schoolRole }).firestore();
}

// One convenience wrapper per real role — reads cleaner at call sites
// than staffContext(testEnv, uid, schoolId, 'head_teacher') everywhere.
export function teacherContext(testEnv, uid, schoolId) {
  return staffContext(testEnv, uid, schoolId, 'teacher');
}
export function gradeTeacherContext(testEnv, uid, schoolId) {
  return staffContext(testEnv, uid, schoolId, 'grade_teacher');
}
export function headTeacherContext(testEnv, uid, schoolId) {
  return staffContext(testEnv, uid, schoolId, 'head_teacher');
}
export function deputyContext(testEnv, uid, schoolId) {
  return staffContext(testEnv, uid, schoolId, 'deputy');
}
export function administratorContext(testEnv, uid, schoolId) {
  return staffContext(testEnv, uid, schoolId, 'administrator');
}
export function observerContext(testEnv, uid, schoolId) {
  return staffContext(testEnv, uid, schoolId, 'observer');
}

/** A linked pupil: pupilSchoolId/pupilClassId custom claims, stamped in
 * reality only by respondToPupilClassLink. Deliberately carries no
 * schoolId/schoolRole at all — a pupil token is never a staff token,
 * even a weak one. */
export function pupilContext(testEnv, uid, pupilSchoolId, pupilClassId) {
  return testEnv.authenticatedContext(uid, { pupilSchoolId, pupilClassId }).firestore();
}

/** Teacher Submissions Dashboard access: a `teacherEmail` custom claim,
 * stamped only by verifyDashboardAccessCode after the caller proves
 * inbox ownership. A third claim namespace, independent of both staff
 * and pupil claims. */
export function teacherEmailContext(testEnv, uid, teacherEmail) {
  return testEnv.authenticatedContext(uid, { teacherEmail }).firestore();
}

/** Authenticated (real Firebase Auth uid) but zero custom claims — e.g.
 * a brand-new sign-in before any Cloud Function has stamped anything
 * onto their token. Satisfies no schoolId/schoolRole/pupilSchoolId/
 * pupilClassId/teacherEmail check anywhere in firestore.rules. */
export function randoContext(testEnv, uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

/** No Firebase Auth session at all. */
export function anonContext(testEnv) {
  return testEnv.unauthenticatedContext().firestore();
}
