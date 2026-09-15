// Impersonation/tampering coverage: can a client forge its way to
// access it shouldn't have, either by writing to a document it owns
// (teacher_profiles self-tamper), or by attaching someone else's
// identity to a write (staffroom authorUid spoofing, teacher_profiles/
// notifications cross-user read)?
//
// pupilClassLinks uid-spoofing and empty/missing learnerName are
// already covered by firestore.rules.test.mjs's own 'pupilClassLinks'
// describe block — not duplicated here.

import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';
import { staffContext, randoContext } from './fixtures.mjs';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-impersonation',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: 'localhost',
      port: 8089,
    },
  });

  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const seeds = [
      ['teacher_profiles/uid-1', { schoolId: 'school-A', schoolRole: 'teacher' }],
      ['teacher_profiles/uid-1/notifications/notif-1', { message: 'hi', read: false }],
      ['teacher_profiles/uid-2', { schoolId: 'school-B', schoolRole: 'teacher' }],

      ['schools/school-B', { name: 'School B' }],
      ['schools/school-A/staffroom/post-1', { authorUid: 'uid-1', pinned: false, text: 'hi' }],
    ];
    for (const [path, data] of seeds) {
      await setDoc(doc(db, path), data);
    }
  });
});

after(async () => {
  await testEnv.cleanup();
});

describe('teacher_profiles — owner-only read/write', () => {
  it('the owner CAN read and write their own profile', async () => {
    const db = randoContext(testEnv, 'uid-1');
    await assertSucceeds(getDoc(doc(db, 'teacher_profiles/uid-1')));
    await assertSucceeds(setDoc(doc(db, 'teacher_profiles/uid-1'), { schoolId: 'school-A', schoolRole: 'teacher', bio: 'hi' }));
  });

  it('a DIFFERENT authenticated user CANNOT read or write someone else\'s profile', async () => {
    const db = randoContext(testEnv, 'uid-2');
    await assertFails(getDoc(doc(db, 'teacher_profiles/uid-1')));
    await assertFails(setDoc(doc(db, 'teacher_profiles/uid-1'), { schoolId: 'school-B', schoolRole: 'head_teacher' }));
  });
});

describe('teacher_profiles/notifications — owner read+update only, create/delete always false', () => {
  it('the owner CAN read and update (mark read) their own notification', async () => {
    const db = randoContext(testEnv, 'uid-1');
    await assertSucceeds(getDoc(doc(db, 'teacher_profiles/uid-1/notifications/notif-1')));
    await assertSucceeds(updateDoc(doc(db, 'teacher_profiles/uid-1/notifications/notif-1'), { read: true }));
  });

  it('the owner CANNOT create a new notification or delete an existing one — only Cloud Functions may', async () => {
    const db = randoContext(testEnv, 'uid-1');
    await assertFails(setDoc(doc(db, 'teacher_profiles/uid-1/notifications/notif-new'), { message: 'fake', read: false }));
    await assertFails(deleteDoc(doc(db, 'teacher_profiles/uid-1/notifications/notif-1')));
  });

  it('a DIFFERENT authenticated user CANNOT read another owner\'s notification', async () => {
    const db = randoContext(testEnv, 'uid-2');
    await assertFails(getDoc(doc(db, 'teacher_profiles/uid-1/notifications/notif-1')));
  });
});

describe('teacher_profiles self-tamper is harmless by design (both halves proven, not assumed)', () => {
  it('(a) the owner CAN write a fake elevated schoolId/schoolRole onto their own profile doc — expected, not a bug', async () => {
    const db = randoContext(testEnv, 'uid-1');
    await assertSucceeds(
      setDoc(doc(db, 'teacher_profiles/uid-1'), {
        schoolId: 'school-B',
        schoolRole: 'head_teacher',
      })
    );
  });

  it('(b) that fake doc data grants NO real access — the SAME uid\'s actual token claims (independent of Firestore content in the test harness, exactly like a real ID token) are still school-A/teacher', async () => {
    // uid-1's real ID token, per every actual access check in
    // firestore.rules, still says schoolId=school-A/schoolRole=teacher —
    // the fake-context claims here are set independently of whatever the
    // previous test wrote into teacher_profiles/uid-1, exactly like the
    // real world where only a Cloud Function can change token claims.
    const db = staffContext(testEnv, 'uid-1', 'school-A', 'teacher');

    // Still can't read School B, despite the profile doc now claiming
    // schoolId: 'school-B'.
    await assertFails(getDoc(doc(db, 'schools/school-B')));

    // Still can't pin/unpin — a leadership-only action — despite the
    // profile doc now claiming schoolRole: 'head_teacher'. post-1 is
    // uid-1's own post, isolating this to the role check specifically
    // (ownership alone doesn't allow flipping pinned).
    await assertFails(updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { pinned: true }));
  });
});

describe('Staffroom authorUid spoofing on create is blocked', () => {
  it('CANNOT create a post claiming someone else\'s authorUid', async () => {
    const db = staffContext(testEnv, 'staff-a', 'school-A', 'teacher');
    await assertFails(
      setDoc(doc(db, 'schools/school-A/staffroom/post-spoofed'), {
        authorUid: 'someone-else',
        pinned: false,
        text: 'spoofed authorship',
      })
    );
  });
});
