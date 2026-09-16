# firestore.rules test coverage

This is a living checklist, not a one-time report. **When you add a new
collection (or a new field-level rule) to `firestore.rules`, add a row
here and a corresponding test** — that's the whole point of this file:
stop a new collection from silently shipping with zero rules coverage.

Test files, by concern:

| File | Concern |
|---|---|
| `fixtures.mjs` | Reusable fake-context builders (not a test file itself) |
| `firestore.rules.test.mjs` | Original/core suite: basic cross-school reads, pupil read scope, no-direct-write sanity, pupilClassLinks, staffroom pin basics, guardianContacts role basics |
| `firestore.rules.cross-school.test.mjs` | Cross-school isolation for every collection not already covered by the core suite |
| `firestore.rules.namespace-separation.test.mjs` | Pupil claims vs staff claims never cross-satisfy each other's checks |
| `firestore.rules.impersonation.test.mjs` | Self-tamper, cross-user, and authorUid-spoofing attempts |
| `firestore.rules.role-boundaries.test.mjs` | The handful of real schoolRole checks, exercised across all 6 roles; the Staffroom observer-write finding |
| `storage.rules.test.mjs` | Storage rules (school logo) — pre-existing, out of this task's scope |

## Coverage matrix

Legend: R = read, W = write (create/update/delete as applicable). "—"
means not applicable (e.g. a collection with `allow write: if false` has
no role-gating to test on writes).

| Collection | R tested | W tested | Cross-school / cross-user isolation | Role-gating tested | Files |
|---|---|---|---|---|---|
| `submissions/{id}` (top-level, teacherEmail-gated) | ✅ | ✅ (always false) | ✅ cross-teacher (own vs. another teacherEmail) | — (claim-gated, not role-gated) | cross-school |
| `dashboardAccessCodes/{id}` | ✅ (always false) | ✅ (always false) | ✅ (no claim shape helps, incl. leadership-shaped) | — | cross-school |
| `teacher_profiles/{uid}` | ✅ | ✅ | ✅ cross-user (owner-only) | — (uid-gated, not role-gated) | impersonation |
| `teacher_profiles/{uid}/notifications/{id}` | ✅ | ✅ (create/delete always false; update owner-only) | ✅ cross-user | — | impersonation |
| `schools/{id}` | ✅ | ✅ (always false) | ✅ cross-school | — | cross-school, namespace-separation |
| `schools/{id}/members/{uid}` | ✅ | ✅ (always false) | ✅ cross-school | — | cross-school, namespace-separation |
| `schools/{id}/classes/{id}` | ✅ | ✅ (always false) | ✅ cross-school (staff + pupil) | — (schoolId-only, no role check) | core, cross-school, namespace-separation |
| `.../pupilClassLinks/{pupilUid}` | ✅ | ✅ create (uid+learnerName gated); update/delete always false | ✅ cross-school read; create confirmed NOT school-scoped by design (see Findings) | — | core, cross-school |
| `.../homeAssignments/{id}` | ✅ | ✅ (always false) | ✅ cross-school (staff + pupil) | — | core, cross-school |
| `.../homeAssignments/{id}/submissions/{id}` | ✅ | ✅ (always false) | ✅ cross-school (staff + pupil) | — | core, cross-school |
| `.../scoreEntries/{id}` | ✅ | ✅ (always false) | ✅ cross-school | — (schoolId-only, no role check) | cross-school, namespace-separation |
| `.../guardianContacts/{id}` | ✅ | ✅ (always false) | ✅ cross-school (leadership role alone isn't enough) | ✅ all 6 roles (3 leadership yes / 3 non-leadership no) | core, cross-school, role-boundaries |
| `schools/{id}/staffroom/{id}` | ✅ | ✅ create/update/delete | ✅ cross-school (read AND write, incl. stale-token-with-matching-authorUid case) | ✅ pin/unpin across all 6 roles; posting restricted to non-observer roles (fixed 2026-09-15, see below); authorUid-spoofing blocked; leadership delete-moderation verified | core, cross-school, impersonation, role-boundaries |
| `schools/{id}/timetable/{id}` | ✅ | ✅ (always false) | ✅ cross-school | — (schoolId-only, no role check) | core, namespace-separation |
| `unmatchedHomeAssignmentSubmissions/{id}` | ✅ | ✅ (always false) | ✅ cross-school (readable only once `schoolId` is resolved); an unresolved item (`schoolId` absent) confirmed readable by nobody via the app | — (schoolId-only, no role check) | cross-school |
| `independentTimetableProjects/{id}` (+ `classes`, `timetable`) | ✅ | ✅ (always false) | ✅ cross-user (`ownerUid` field equality, not the `schoolId` claim — confirmed a real staff token gains no extra access) | — (ownerUid-only, no role check; never gated on School Network membership by design) | cross-school |

Pupil/staff claim-namespace separation (pupilSchoolId/pupilClassId vs.
schoolId/schoolRole never cross-satisfying each other, including string
collisions and a hypothetical dual-claim token) is covered end-to-end in
`firestore.rules.namespace-separation.test.mjs` against classes,
homeAssignments, scoreEntries, guardianContacts, members, staffroom,
timetable, and the schools doc.

## Findings for the project owner (not fixed here — this task tests
## current behavior, it doesn't change `firestore.rules`)

1. ~~**Staffroom write has no schoolRole restriction beyond pin/leadership.**~~
   **FIXED 2026-09-15**, same day this was found, per explicit confirmation
   of the intended policy: every teaching role may post, `observer` may
   not (`firestore.rules`' staffroom `allow create` now checks
   `schoolRole != "observer"`), and leadership (head_teacher/deputy/
   administrator) retains its existing power to delete anyone's post —
   already true before this fix, now also explicitly tested per-role in
   `firestore.rules.role-boundaries.test.mjs`.

2. **`teacher_profiles/{uid}` self-tamper is harmless, by design — proven,
   not assumed.** The owner can write any fields, including a fake
   elevated `schoolId`/`schoolRole`, onto their own profile doc (that
   succeeds — expected). But every real access check elsewhere in
   `firestore.rules` reads `request.auth.token.schoolId`/`schoolRole`
   (the ID token's custom claims, set only by Cloud Functions), never
   this document — so the fake doc data grants no elevated access
   anywhere. Proven in `firestore.rules.impersonation.test.mjs` by using
   the same uid's real (fake-context) token, independent of what was just
   written to its own profile doc, and confirming it still can't read
   another school or flip a staffroom pin.

3. **`pupilClassLinks` create has no schoolId check at all.** The create
   rule is only `auth.uid == pupilUid` + a valid `learnerName` — no
   schoolId/pupilSchoolId comparison. That's necessary, not a bug: a
   pupil has no claims yet the first time they self-register a pending
   link. The practical consequence is that any authenticated uid, with
   zero claims, can create a pending link under ANY school's ANY class —
   it just sits unreviewed until staff of that school approve or reject
   it via `respondToPupilClassLink`. Proven in
   `firestore.rules.cross-school.test.mjs`.

4. **A token carrying BOTH staff and pupil claims gets both halves'
   access, independently.** The real Cloud Functions never issue both
   claim sets to the same account, but nothing in the rule text itself
   prevents it — the classes/homeAssignments pupil OR-clause and any
   schoolId-only check are each evaluated purely from whatever's on the
   token, with no "pick one identity" cross-check. Documented as current
   behavior in `firestore.rules.namespace-separation.test.mjs`; not
   exploitable today since claim issuance is Cloud-Functions-controlled,
   but worth knowing if that ever changes.

None of `firestore.rules`'s own rule text or comments were found to
contradict what this suite exercises — every rule behaved exactly as its
own inline comment describes.

## NOT covered by this suite, and why

- **The Report Form Pipeline (Broad Mark Sheet / "Grade Teacher"
  roster/report forms).** 100% on-device SQLite
  (`lib/services/report_class_repository.dart` etc.), never synced to
  Firestore. There is no collection to test.
- **Cloud-Functions-internal business-logic role checks** — e.g. "only
  grade_teacher/head_teacher/deputy can override another teacher's score
  entry," "only head_teacher/deputy can sign report forms,"
  administrator's deadline-view-only access, `callerCanManageTimetable`/
  `schoolMeetsTimetableTier` in `functions/src/index.ts`, and the
  Timetable Operator boolean field. None of this is enforced by
  `firestore.rules` — nearly every collection here is
  `allow write: if false` and the real logic lives in the Admin-SDK
  Cloud Functions themselves. That's a Cloud Functions unit/integration
  test suite, a different kind of test than this one; not built here.
- **`firestore.indexes.json`** — index configuration isn't a security
  boundary and has no rules-relevant behavior to test.
- **Storage rules beyond the school logo** — `storage.rules.test.mjs`
  pre-dates this task and wasn't expanded; if Storage gains new paths,
  it needs its own coverage pass.
