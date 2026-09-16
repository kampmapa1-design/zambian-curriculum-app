// Cross-school isolation coverage that firestore.rules.test.mjs doesn't
// already exercise: collections/paths it only partly covers (scoreEntries,
// guardianContacts, members, the schools doc itself, homeAssignments
// submissions, staffroom writes, pupilClassLinks reads) plus the two
// collections gated by a completely different claim (top-level
// `submissions` by teacherEmail, `dashboardAccessCodes` never at all).
//
// Uses its own emulator "project" (projectId) so its seed data can't
// collide with firestore.rules.test.mjs's, even though both run against
// the same emulator instance in one `emulators:exec` invocation.

import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';
import {
  staffContext,
  headTeacherContext,
  pupilContext,
  teacherEmailContext,
  randoContext,
} from './fixtures.mjs';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-cross-school',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: 'localhost',
      port: 8089,
    },
  });

  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const seeds = [
      ['schools/school-A', { name: 'School A' }],
      ['schools/school-B', { name: 'School B' }],

      ['schools/school-A/members/staff-a-m', { role: 'teacher' }],
      ['schools/school-B/members/staff-b-m', { role: 'teacher' }],

      ['schools/school-A/classes/class-1', { name: 'Class 1' }],
      ['schools/school-B/classes/class-9', { name: 'Class 9' }],

      ['schools/school-A/classes/class-1/scoreEntries/entry-1', { score: 80 }],
      ['schools/school-B/classes/class-9/scoreEntries/entry-9', { score: 70 }],

      ['schools/school-A/classes/class-1/guardianContacts/data', { phone: '0977000000' }],
      ['schools/school-B/classes/class-9/guardianContacts/data', { phone: '0966000000' }],

      ['schools/school-A/classes/class-1/homeAssignments/hw-1', { title: 'HW1' }],
      ['schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-1', { score: 5 }],
      ['schools/school-B/classes/class-9/homeAssignments/hw-9', { title: 'HW9' }],
      ['schools/school-B/classes/class-9/homeAssignments/hw-9/submissions/sub-9', { score: 3 }],

      ['schools/school-A/staffroom/post-a', { authorUid: 'staff-a', pinned: false, text: 'a' }],
      ['schools/school-B/staffroom/post-b', { authorUid: 'staff-b', pinned: false, text: 'b' }],

      ['schools/school-A/classes/class-1/pupilClassLinks/pupil-a-existing', { learnerName: 'Pupil A' }],
      ['schools/school-B/classes/class-9/pupilClassLinks/pupil-b-existing', { learnerName: 'Pupil B' }],

      ['submissions/sub-teacher-a', { teacherEmail: 'teacher-a@example.com', text: 'x' }],
      ['submissions/sub-teacher-b', { teacherEmail: 'teacher-b@example.com', text: 'y' }],

      ['dashboardAccessCodes/code-1', { code: '123456' }],

      ['unmatchedHomeAssignmentSubmissions/unmatched-a', { schoolId: 'school-A', reason: 'sender-not-on-roster' }],
      ['unmatchedHomeAssignmentSubmissions/unmatched-b', { schoolId: 'school-B', reason: 'sender-not-on-roster' }],
      ['unmatchedHomeAssignmentSubmissions/unmatched-no-school', { reason: 'no-reference-code' }],
    ];
    for (const [path, data] of seeds) {
      await setDoc(doc(db, path), data);
    }
  });
});

after(async () => {
  await testEnv.cleanup();
});

describe('Cross-school isolation — schools doc', () => {
  it('staff CAN read own school doc, CANNOT read the other school doc', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A')));
    await assertFails(getDoc(doc(db, 'schools/school-B')));
  });

  it('direct client write to a school doc always fails, even matching-school staff', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A'), { name: 'Hacked' }));
  });
});

describe('Cross-school isolation — members', () => {
  it('staff CAN read own school member doc, CANNOT read the other school\'s', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/members/staff-a-m')));
    await assertFails(getDoc(doc(db, 'schools/school-B/members/staff-b-m')));
  });

  it('direct client write to a member doc always fails, even matching-school staff', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/members/staff-a-m'), { role: 'head_teacher' }));
  });
});

describe('Cross-school isolation — scoreEntries', () => {
  it('staff CAN read own school\'s entry, CANNOT read the other school\'s', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/scoreEntries/entry-1')));
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9/scoreEntries/entry-9')));
  });

  it('direct client write to scoreEntries always fails, even matching-school staff', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/classes/class-1/scoreEntries/entry-new'), { score: 99 }));
  });
});

describe('Cross-school isolation — guardianContacts', () => {
  it('leadership CAN read own school\'s guardianContacts, but the SAME leadership role CANNOT read the other school\'s — role alone is not enough, schoolId must also match', async () => {
    const db = headTeacherContext(testEnv, 'lead-a', 'school-A');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/guardianContacts/data')));
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9/guardianContacts/data')));
  });

  it('direct client write to guardianContacts always fails, even matching-school leadership', async () => {
    const db = headTeacherContext(testEnv, 'lead-a', 'school-A');
    await assertFails(setDoc(doc(db, 'schools/school-A/classes/class-1/guardianContacts/data'), { phone: 'x' }));
  });
});

describe('Cross-school isolation — homeAssignments submissions', () => {
  it('staff CAN read own school\'s submission, CANNOT read the other school\'s', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-1')));
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9/homeAssignments/hw-9/submissions/sub-9')));
  });

  it('a linked pupil CAN read their own class\'s submission, CANNOT read the other school\'s', async () => {
    const db = pupilContext(testEnv, 'pupil-a1', 'school-A', 'class-1');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-1')));
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9/homeAssignments/hw-9/submissions/sub-9')));
  });

  it('direct client write to a submission always fails, even matching-school staff', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-new'), { score: 1 }));
  });
});

describe('Cross-school isolation — unmatchedHomeAssignmentSubmissions (Stage 2b/3)', () => {
  it('staff CAN read their own school\'s unmatched item, CANNOT read the other school\'s', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'unmatchedHomeAssignmentSubmissions/unmatched-a')));
    await assertFails(getDoc(doc(db, 'unmatchedHomeAssignmentSubmissions/unmatched-b')));
  });

  it('an item with no resolved schoolId is readable by nobody via the app', async () => {
    await assertFails(getDoc(doc(staffContext(testEnv, 'staff-a', 'school-A', 'teacher'), 'unmatchedHomeAssignmentSubmissions/unmatched-no-school')));
    await assertFails(getDoc(doc(headTeacherContext(testEnv, 'lead-a', 'school-A'), 'unmatchedHomeAssignmentSubmissions/unmatched-no-school')));
  });

  it('direct client write always fails, even matching-school staff', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'unmatchedHomeAssignmentSubmissions/unmatched-a'), { resolved: true }));
    await assertFails(setDoc(doc(db, 'unmatchedHomeAssignmentSubmissions/new-one'), { schoolId: 'school-A' }));
  });
});

describe('Cross-school isolation — staffroom writes (not just reads)', () => {
  it('staff CANNOT create a post under the OTHER school\'s path, even with a well-formed authorUid/pinned', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(
      setDoc(doc(db, 'schools/school-B/staffroom/post-cross'), {
        authorUid: 'staff-a',
        pinned: false,
        text: 'sneaking into school B',
      })
    );
  });

  it('owning a post is not enough to edit/delete it from the WRONG school token — schoolId must also match', async () => {
    // staff-b really authored post-b, but here their token still carries
    // school-A (imagine a stale/mismatched token) — the schoolId gate
    // must block them even though resource.data.authorUid == auth.uid.
    const staleDb = staffContext(testEnv, 'staff-b', 'school-A', 'teacher');
    await assertFails(updateDoc(doc(staleDb, 'schools/school-B/staffroom/post-b'), { text: 'edited' }));
    await assertFails(deleteDoc(doc(staleDb, 'schools/school-B/staffroom/post-b')));
  });
});

describe('Cross-school isolation — pupilClassLinks reads', () => {
  it('staff CAN read own school\'s pending link, CANNOT read the other school\'s', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-a-existing')));
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9/pupilClassLinks/pupil-b-existing')));
  });
});

describe('pupilClassLinks create is NOT school-scoped (by design, confirm rather than assume)', () => {
  // The create rule only checks request.auth.uid == pupilUid and a valid
  // learnerName — no schoolId/pupilSchoolId check at all. That's by
  // design: a pupil has no claims yet the first time they self-register
  // a pending link, so there's nothing school-shaped to check against.
  // Any authenticated uid can therefore create a pending link under ANY
  // school's any class, at their own uid — it just sits unreviewed until
  // staff of that school approve/reject it via respondToPupilClassLink.
  it('an authenticated user with NO claims at all can still create a pending link in any school\'s class', async () => {
    const db = randoContext(testEnv, 'totally-unrelated-uid');
    await assertSucceeds(
      setDoc(doc(db, 'schools/school-B/classes/class-9/pupilClassLinks/totally-unrelated-uid'), {
        learnerName: 'Some Kid',
      })
    );
  });
});

describe('Top-level submissions (Teacher Dashboard) — teacherEmail-gated, not school-gated', () => {
  it('a teacherEmail-claim holder CAN read their own mailbox submission, CANNOT read another teacher\'s', async () => {
    const db = teacherEmailContext(testEnv, 'uid-teacher-a', 'teacher-a@example.com');
    await assertSucceeds(getDoc(doc(db, 'submissions/sub-teacher-a')));
    await assertFails(getDoc(doc(db, 'submissions/sub-teacher-b')));
  });

  it('direct client write to a submission always fails, even the matching teacherEmail owner', async () => {
    const db = teacherEmailContext(testEnv, 'uid-teacher-a', 'teacher-a@example.com');
    await assertFails(setDoc(doc(db, 'submissions/sub-teacher-a'), { text: 'forged' }));
    await assertFails(setDoc(doc(db, 'submissions/sub-new'), { teacherEmail: 'teacher-a@example.com', text: 'forged' }));
  });
});

describe('dashboardAccessCodes — never client-accessible, by anyone', () => {
  it('not even the matching teacherEmail owner can read or write a code', async () => {
    const db = teacherEmailContext(testEnv, 'uid-teacher-a', 'teacher-a@example.com');
    await assertFails(getDoc(doc(db, 'dashboardAccessCodes/code-1')));
    await assertFails(setDoc(doc(db, 'dashboardAccessCodes/code-1'), { code: '000000' }));
  });

  it('leadership/head_teacher-shaped claims do not help either — this collection has no claim path at all', async () => {
    const db = headTeacherContext(testEnv, 'lead-a', 'school-A');
    await assertFails(getDoc(doc(db, 'dashboardAccessCodes/code-1')));
  });
});
