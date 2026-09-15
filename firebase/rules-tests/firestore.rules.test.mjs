// Automated security-rules test suite for firebase/firestore.rules, run
// against the Firebase Local Emulator Suite (never against production).
//
// Run with: npm test   (from firebase/rules-tests)
//   — which runs `firebase emulators:exec` from firebase/, starting the
//   Firestore + Storage emulators, running this suite (and the storage
//   suite) against them, then shutting the emulators down automatically.
//
// Seeds documents via a security-rules-disabled admin context, then
// asserts reads/writes under various fake authenticated contexts
// (matching/mismatching schoolId, pupilSchoolId/pupilClassId, and role
// claims) using assertSucceeds/assertFails from
// @firebase/rules-unit-testing.

import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
} from 'firebase/firestore';
import {
  staffContext,
  pupilContext,
  anonContext,
  randoContext,
} from './fixtures.mjs';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-firestore',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: 'localhost',
      port: 8089,
    },
  });

  // Seed baseline fixture data, bypassing rules entirely (this is what
  // the real Cloud Functions do via the Admin SDK).
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const seeds = [
      ['schools/school-A/classes/class-1', { name: 'Class 1' }],
      ['schools/school-A/classes/class-2', { name: 'Class 2' }],
      ['schools/school-B/classes/class-9', { name: 'Class 9' }],

      ['schools/school-A/timetable/config', { days: ['Mon'] }],
      ['schools/school-B/timetable/config', { days: ['Mon'] }],

      ['schools/school-A/staffroom/post-1', { authorUid: 'staff-a', pinned: false, text: 'hello' }],
      ['schools/school-B/staffroom/post-b', { authorUid: 'staff-b', pinned: false, text: 'hi' }],

      ['schools/school-A/classes/class-1/homeAssignments/hw-1', { title: 'HW1' }],
      ['schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-1', { score: 5 }],
      ['schools/school-A/classes/class-2/homeAssignments/hw-2', { title: 'HW2' }],

      ['schools/school-A/classes/class-1/guardianContacts/data', { phone: '0977000000' }],

      ['schools/school-A/classes/class-1/pupilClassLinks/pupil-existing', { learnerName: 'Existing Pupil' }],

      ['schools/school-A/classes/class-1/scoreEntries/entry-1', { score: 80 }],
    ];
    for (const [path, data] of seeds) {
      await setDoc(doc(db, path), data);
    }
  });
});

after(async () => {
  await testEnv.cleanup();
});

// --- Fake authenticated contexts -------------------------------------
// Thin wrappers over fixtures.mjs's builders, which take testEnv
// explicitly (it doesn't exist until before() runs); these close over
// the module-level `testEnv` so call sites below stay unchanged.
function staff(uid, schoolId, schoolRole) {
  return staffContext(testEnv, uid, schoolId, schoolRole);
}
function pupil(uid, pupilSchoolId, pupilClassId) {
  return pupilContext(testEnv, uid, pupilSchoolId, pupilClassId);
}
function anon() {
  return anonContext(testEnv);
}
function rando(uid) {
  return randoContext(testEnv, uid);
}

describe('Cross-school isolation', () => {
  it('school-A staff CAN read a school-A class', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1')));
  });

  it('school-A staff CANNOT read a school-B class', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9')));
  });

  it('school-A staff CAN read school-A timetable, CANNOT read school-B timetable', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/timetable/config')));
    await assertFails(getDoc(doc(db, 'schools/school-B/timetable/config')));
  });

  it('school-A staff CAN read school-A staffroom, CANNOT read school-B staffroom', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/staffroom/post-1')));
    await assertFails(getDoc(doc(db, 'schools/school-B/staffroom/post-b')));
  });

  it('school-A staff CAN read school-A homeAssignments, CANNOT read a school-B equivalent path', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1')));
    // school-B has no homeAssignments seeded under class-9, but the read
    // should be denied by the rule (schoolId mismatch) before it even
    // matters whether the doc exists.
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9/homeAssignments/hw-x')));
  });
});

describe('Pupil read scope', () => {
  it('a linked pupil CAN read their own class doc', async () => {
    const db = pupil('pupil-a1', 'school-A', 'class-1');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1')));
  });

  it('a linked pupil CAN read their own class homeAssignment and its submissions', async () => {
    const db = pupil('pupil-a1', 'school-A', 'class-1');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1')));
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-1')));
  });

  it('a pupil CANNOT read a different class in the SAME school', async () => {
    const db = pupil('pupil-a1', 'school-A', 'class-1');
    await assertFails(getDoc(doc(db, 'schools/school-A/classes/class-2')));
    await assertFails(getDoc(doc(db, 'schools/school-A/classes/class-2/homeAssignments/hw-2')));
  });

  it('a pupil CANNOT read anything in a different school', async () => {
    const db = pupil('pupil-a1', 'school-A', 'class-1');
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-9')));
  });
});

describe('No direct client writes to Cloud-Function-only collections', () => {
  it('classes: direct client write fails even for matching-school staff', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/classes/class-1'), { name: 'Hacked' }));
  });

  it('homeAssignments: direct client write fails even for matching-school staff', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-new'), { title: 'x' }));
  });

  it('homeAssignments submissions: direct client write fails even for matching-school staff', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/classes/class-1/homeAssignments/hw-1/submissions/sub-new'), { score: 1 }));
  });

  it('timetable: direct client write fails even for matching-school staff', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertFails(setDoc(doc(db, 'schools/school-A/timetable/config'), { days: ['Tue'] }));
  });
});

describe('pupilClassLinks', () => {
  it('a pupil CAN create their own link doc with a valid learnerName', async () => {
    const db = pupil('pupil-a1', 'school-A', 'class-1');
    await assertSucceeds(
      setDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-a1'), {
        learnerName: 'Pupil A1',
      })
    );
  });

  it('a pupil CANNOT create a link doc at a different uid than their own', async () => {
    const db = pupil('pupil-a1', 'school-A', 'class-1');
    await assertFails(
      setDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/someone-else'), {
        learnerName: 'Impersonated',
      })
    );
  });

  it('a pupil CANNOT create a link doc with an empty/missing learnerName', async () => {
    const db = pupil('pupil-empty', 'school-A', 'class-1');
    await assertFails(
      setDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-empty'), {
        learnerName: '',
      })
    );
    await assertFails(
      setDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-empty'), {
        somethingElse: true,
      })
    );
  });

  it('nobody can update or delete a pupilClassLinks doc, including its own owner', async () => {
    const db = pupil('pupil-existing', 'school-A', 'class-1');
    await assertFails(
      updateDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-existing'), {
        learnerName: 'Changed',
      })
    );
    await assertFails(deleteDoc(doc(db, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-existing')));
  });

  it('staff of the school CAN read pending links; an unrelated user CANNOT', async () => {
    const staffDb = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(getDoc(doc(staffDb, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-existing')));

    const randoDb = rando('some-rando');
    await assertFails(getDoc(doc(randoDb, 'schools/school-A/classes/class-1/pupilClassLinks/pupil-existing')));
  });
});

describe('Staffroom', () => {
  it('a member CAN create a post with pinned:false and their own authorUid', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(
      setDoc(doc(db, 'schools/school-A/staffroom/post-new'), {
        authorUid: 'staff-a',
        pinned: false,
        text: 'new post',
      })
    );
  });

  it('CANNOT create a post with pinned:true directly', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertFails(
      setDoc(doc(db, 'schools/school-A/staffroom/post-pinned-attempt'), {
        authorUid: 'staff-a',
        pinned: true,
        text: 'sneaky pin',
      })
    );
  });

  it('a non-leadership author CAN update their own post text, but NOT flip pinned', async () => {
    const db = staff('staff-a', 'school-A', 'teacher');
    await assertSucceeds(
      updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { text: 'edited text' })
    );
    await assertFails(
      updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { pinned: true })
    );
  });

  it('leadership CAN flip pinned even on someone else\'s post', async () => {
    const db = staff('staff-a-lead', 'school-A', 'head_teacher');
    await assertSucceeds(
      updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { pinned: true })
    );
    // reset for isolation of subsequent tests
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'schools/school-A/staffroom/post-1'), {
        authorUid: 'staff-a',
        pinned: false,
        text: 'hello',
      });
    });
  });
});

describe('guardianContacts', () => {
  it('head_teacher/deputy/administrator CAN read', async () => {
    await assertSucceeds(getDoc(doc(staff('lead-1', 'school-A', 'head_teacher'), 'schools/school-A/classes/class-1/guardianContacts/data')));
    await assertSucceeds(getDoc(doc(staff('lead-2', 'school-A', 'deputy'), 'schools/school-A/classes/class-1/guardianContacts/data')));
    await assertSucceeds(getDoc(doc(staff('lead-3', 'school-A', 'administrator'), 'schools/school-A/classes/class-1/guardianContacts/data')));
  });

  it('a plain teacher or grade_teacher CANNOT read', async () => {
    await assertFails(getDoc(doc(staff('t-1', 'school-A', 'teacher'), 'schools/school-A/classes/class-1/guardianContacts/data')));
    await assertFails(getDoc(doc(staff('t-2', 'school-A', 'grade_teacher'), 'schools/school-A/classes/class-1/guardianContacts/data')));
  });
});

describe('sanity: unauthenticated access', () => {
  it('an unauthenticated client cannot read a school-A class', async () => {
    await assertFails(getDoc(doc(anon(), 'schools/school-A/classes/class-1')));
  });
});
