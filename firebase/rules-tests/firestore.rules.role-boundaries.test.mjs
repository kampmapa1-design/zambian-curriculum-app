// Within-school role-boundary coverage: the handful of things
// firestore.rules actually gates on schoolRole (staffroom posting,
// staffroom pin/unpin, guardianContacts read).
//
// Everything else that might sound like a role check (who can override
// a score entry, who can sign a report form, administrator's deadline-
// view-only access) is enforced inside Cloud Functions TypeScript, not
// firestore.rules — out of scope for this suite. See COVERAGE.md.

import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc } from 'firebase/firestore';
import { staffContext, SCHOOL_ROLES, LEADERSHIP_ROLES } from './fixtures.mjs';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-role-boundaries',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: 'localhost',
      port: 8089,
    },
  });

  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const seeds = [
      ['schools/school-A/staffroom/post-1', { authorUid: 'other-author', pinned: false, text: 'hi' }],
      ['schools/school-A/classes/class-1/guardianContacts/data', { phone: '0977000000' }],
    ];
    for (const [path, data] of seeds) {
      await setDoc(doc(db, path), data);
    }
  });
});

after(async () => {
  await testEnv.cleanup();
});

describe('Staffroom pin/unpin — all 3 leadership roles CAN, non-leadership roles CANNOT', () => {
  const nonLeadership = SCHOOL_ROLES.filter((r) => !LEADERSHIP_ROLES.includes(r));

  for (const role of LEADERSHIP_ROLES) {
    it(`${role} CAN flip pinned on someone else's post`, async () => {
      const db = staffContext(testEnv, `lead-${role}`, 'school-A', role);
      await assertSucceeds(updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { pinned: true }));
      // reset for isolation of subsequent tests
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), 'schools/school-A/staffroom/post-1'), {
          authorUid: 'other-author',
          pinned: false,
          text: 'hi',
        });
      });
    });
  }

  for (const role of nonLeadership) {
    it(`${role} (non-leadership) CANNOT flip pinned, even on their OWN post`, async () => {
      const db = staffContext(testEnv, `own-post-${role}`, 'school-A', role);
      // Give this role authorship of the post so the only thing standing
      // between them and success is the leadership check, not ownership.
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), 'schools/school-A/staffroom/post-1'), {
          authorUid: `own-post-${role}`,
          pinned: false,
          text: 'hi',
        });
      });
      await assertFails(updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { pinned: true }));
    });
  }
});

describe('guardianContacts read — only head_teacher/deputy/administrator, confirm the rest of the roster is denied', () => {
  const nonLeadership = SCHOOL_ROLES.filter((r) => !LEADERSHIP_ROLES.includes(r));

  for (const role of nonLeadership) {
    it(`${role} CANNOT read guardianContacts`, async () => {
      const db = staffContext(testEnv, `gc-${role}`, 'school-A', role);
      await assertFails(getDoc(doc(db, 'schools/school-A/classes/class-1/guardianContacts/data')));
    });
  }
});

describe('Staffroom posting — every teaching role CAN, observer CANNOT (2026-09-15, per explicit confirmation)', () => {
  // Was a real, documented gap (no schoolRole check on create at all —
  // an observer could post exactly like a teacher) until this same date,
  // when the project owner confirmed the intended policy: every teacher
  // posts, administrators moderate. Fixed directly in firestore.rules'
  // staffroom `allow create` (added `schoolRole != "observer"`), not
  // left as a documented-but-unfixed finding this time.
  const postingRoles = SCHOOL_ROLES.filter((r) => r !== 'observer');

  for (const role of postingRoles) {
    it(`${role} CAN create their own Staffroom post`, async () => {
      const db = staffContext(testEnv, `post-${role}`, 'school-A', role);
      await assertSucceeds(
        setDoc(doc(db, `schools/school-A/staffroom/post-by-${role}`), {
          authorUid: `post-${role}`,
          pinned: false,
          text: `posted by ${role}`,
        })
      );
    });
  }

  it('observer CANNOT create a Staffroom post', async () => {
    const db = staffContext(testEnv, 'observer-1', 'school-A', 'observer');
    await assertFails(
      setDoc(doc(db, 'schools/school-A/staffroom/observer-post'), {
        authorUid: 'observer-1',
        pinned: false,
        text: 'an observer trying to post',
      })
    );
  });

  it('observer CANNOT edit or delete an existing post either (never an author, never leadership)', async () => {
    const db = staffContext(testEnv, 'observer-1', 'school-A', 'observer');
    await assertFails(updateDoc(doc(db, 'schools/school-A/staffroom/post-1'), { text: 'observer edit attempt' }));
    await assertFails(deleteDoc(doc(db, 'schools/school-A/staffroom/post-1')));
  });
});

describe('Staffroom moderation — administrator (and head_teacher/deputy) CAN delete a teacher\'s post', () => {
  for (const role of LEADERSHIP_ROLES) {
    it(`${role} CAN delete a post authored by a teacher`, async () => {
      await testEnv.withSecurityRulesDisabled(async (ctx) => {
        await setDoc(doc(ctx.firestore(), 'schools/school-A/staffroom/teacher-post-for-mod'), {
          authorUid: 'some-teacher',
          pinned: false,
          text: 'a teacher comment',
        });
      });
      const db = staffContext(testEnv, `mod-${role}`, 'school-A', role);
      await assertSucceeds(deleteDoc(doc(db, 'schools/school-A/staffroom/teacher-post-for-mod')));
    });
  }

  it('a plain teacher CANNOT delete another teacher\'s post', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'schools/school-A/staffroom/teacher-post-for-mod-2'), {
        authorUid: 'some-other-teacher',
        pinned: false,
        text: 'a teacher comment',
      });
    });
    const db = staffContext(testEnv, 'rank-file-teacher', 'school-A', 'teacher');
    await assertFails(deleteDoc(doc(db, 'schools/school-A/staffroom/teacher-post-for-mod-2')));
  });
});
