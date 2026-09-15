// Pupil claims (pupilSchoolId/pupilClassId) and staff claims (schoolId/
// schoolRole) are two separate namespaces in firestore.rules. This file
// proves they stay separate in the ways that matter for real accounts:
//
//   1. A pupil token can never satisfy a schoolId/schoolRole-gated rule,
//      even when pupilSchoolId happens to equal a real schoolId string —
//      only the two rules with an explicit pupil OR-clause
//      (classes, homeAssignments + its submissions) ever look at
//      pupilSchoolId/pupilClassId at all.
//   2. A classId that happens to collide across two different schools
//      doesn't let a pupil of one read the other's class of the same id
//      — the pupil OR-clause checks schoolId AND classId together, not
//      classId alone.
//   3. A token that (hypothetically) carries BOTH claim sets at once —
//      which the real Cloud Functions never do, but rules can't prevent
//      — gets whatever each half's check independently grants. This is
//      documented current behavior, not something being "fixed" here.

import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc } from 'firebase/firestore';
import { staffContext, pupilContext } from './fixtures.mjs';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-namespace-separation',
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
      ['schools/school-A/members/m-a', { role: 'teacher' }],
      ['schools/school-A/staffroom/post-a', { authorUid: 'staff-a', pinned: false, text: 'a' }],
      ['schools/school-A/timetable/config', { days: ['Mon'] }],

      // Deliberate classId collision across two different schools, to
      // prove the pupil OR-clause checks schoolId AND classId together
      // rather than classId alone.
      ['schools/school-A/classes/class-1', { name: 'A1' }],
      ['schools/school-B/classes/class-1', { name: 'B1' }],
      ['schools/school-A/classes/class-1/homeAssignments/hw-1', { title: 'HW-A1' }],
      ['schools/school-A/classes/class-1/scoreEntries/entry-1', { score: 80 }],
      ['schools/school-A/classes/class-1/guardianContacts/data', { phone: 'x' }],
      ['schools/school-B/classes/class-1/scoreEntries/entry-b', { score: 1 }],
    ];
    for (const [path, data] of seeds) {
      await setDoc(doc(db, path), data);
    }
  });
});

after(async () => {
  await testEnv.cleanup();
});

describe('Pupil claims never satisfy schoolId/schoolRole-gated rules, even with a matching string value', () => {
  // Same pupil identity throughout: pupilSchoolId literally equals the
  // real schoolId 'school-A'. If the two namespaces were ever confused,
  // these would incorrectly succeed.
  const pupilDb = () => pupilContext(testEnv, 'pupil-a1', 'school-A', 'class-1');

  it('CANNOT read scoreEntries (schoolId-only gate)', async () => {
    await assertFails(getDoc(doc(pupilDb(), 'schools/school-A/classes/class-1/scoreEntries/entry-1')));
  });

  it('CANNOT read guardianContacts (schoolId + leadership role gate)', async () => {
    await assertFails(getDoc(doc(pupilDb(), 'schools/school-A/classes/class-1/guardianContacts/data')));
  });

  it('CANNOT read members (schoolId-only gate)', async () => {
    await assertFails(getDoc(doc(pupilDb(), 'schools/school-A/members/m-a')));
  });

  it('CANNOT read staffroom (schoolId-only gate)', async () => {
    await assertFails(getDoc(doc(pupilDb(), 'schools/school-A/staffroom/post-a')));
  });

  it('CANNOT read timetable (schoolId-only gate)', async () => {
    await assertFails(getDoc(doc(pupilDb(), 'schools/school-A/timetable/config')));
  });

  it('CANNOT read the schools doc itself (schoolId-only gate)', async () => {
    await assertFails(getDoc(doc(pupilDb(), 'schools/school-A')));
  });

  it('by contrast, the SAME pupil claims CAN read classes and homeAssignments — the only two rules with a pupil OR-clause', async () => {
    await assertSucceeds(getDoc(doc(pupilDb(), 'schools/school-A/classes/class-1')));
    await assertSucceeds(getDoc(doc(pupilDb(), 'schools/school-A/classes/class-1/homeAssignments/hw-1')));
  });
});

describe('A colliding classId across schools does not cross-satisfy the pupil OR-clause', () => {
  it('pupil of school-A/class-1 CAN read school-A\'s class-1, CANNOT read school-B\'s class-1 (same classId string)', async () => {
    const db = pupilContext(testEnv, 'pupil-a1', 'school-A', 'class-1');
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1')));
    await assertFails(getDoc(doc(db, 'schools/school-B/classes/class-1')));
  });

  it('pupil of school-B/class-1 CAN read school-B\'s class-1, CANNOT read school-A\'s class-1 (same classId string, roles reversed)', async () => {
    const db = pupilContext(testEnv, 'pupil-b1', 'school-B', 'class-1');
    await assertSucceeds(getDoc(doc(db, 'schools/school-B/classes/class-1')));
    await assertFails(getDoc(doc(db, 'schools/school-A/classes/class-1')));
  });
});

describe('A token carrying BOTH staff and pupil claims at once (not a real Cloud Functions output, but rules can\'t prevent it) — confirming actual behavior rather than assuming', () => {
  it('a school-B staff token that ALSO carries school-A pupil claims CAN read school-A\'s class via the pupil half of the OR', async () => {
    const db = testEnv
      .authenticatedContext('hybrid-uid-1', {
        schoolId: 'school-B',
        schoolRole: 'teacher',
        pupilSchoolId: 'school-A',
        pupilClassId: 'class-1',
      })
      .firestore();
    // The classes rule is `token.schoolId == schoolId || (token.pupilSchoolId == schoolId && token.pupilClassId == classId)`.
    // schoolId half is false (school-B != school-A) but the pupil half is
    // true — the OR doesn't care that the SAME token also claims to be
    // school-B staff. Each half is evaluated independently.
    await assertSucceeds(getDoc(doc(db, 'schools/school-A/classes/class-1')));
  });

  it('the reverse: that SAME hybrid token\'s schoolId half still independently grants its own school\'s schoolId-only-gated data', async () => {
    const db = testEnv
      .authenticatedContext('hybrid-uid-1', {
        schoolId: 'school-B',
        schoolRole: 'teacher',
        pupilSchoolId: 'school-A',
        pupilClassId: 'class-1',
      })
      .firestore();
    // scoreEntries has no pupil OR-clause at all — only token.schoolId is
    // ever checked, and it's honored regardless of the extra pupil claims
    // riding along on the same token.
    await assertSucceeds(getDoc(doc(db, 'schools/school-B/classes/class-1/scoreEntries/entry-b')));
  });
});
