// Within-school role-boundary coverage: the handful of things
// firestore.rules actually gates on schoolRole (staffroom pin/unpin,
// guardianContacts read) — plus one real, deliberately-NOT-fixed gap
// this task was asked to document rather than patch: staffroom writes
// have no schoolRole restriction beyond the pin/leadership distinction,
// so an `observer` can create/edit/delete their own posts exactly like
// a `teacher` can.
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

describe('FINDING (not a bug being fixed here — real current behavior): Staffroom write has no schoolRole restriction beyond pin/leadership', () => {
  // firestore.rules' staffroom create/update/delete rules check
  // "is this a school member" and "is this their own post, or are they
  // leadership" — nothing else. There is no role allowlist/denylist for
  // who may post at all. An `observer` — whose name suggests read-only
  // participation — can create, edit, and delete their own posts exactly
  // like a `teacher` can. lib/screens/staffroom_screen.dart has no
  // client-side restriction either (confirmed absent by inspection).
  // Flagging for the project owner to decide on; firestore.rules is left
  // unchanged per this task's scope.
  it('an observer CAN create their own Staffroom post', async () => {
    const db = staffContext(testEnv, 'observer-1', 'school-A', 'observer');
    await assertSucceeds(
      setDoc(doc(db, 'schools/school-A/staffroom/observer-post'), {
        authorUid: 'observer-1',
        pinned: false,
        text: 'an observer posting, currently allowed',
      })
    );
  });

  it('an observer CAN edit their own Staffroom post text', async () => {
    const db = staffContext(testEnv, 'observer-1', 'school-A', 'observer');
    await assertSucceeds(
      updateDoc(doc(db, 'schools/school-A/staffroom/observer-post'), { text: 'edited by the observer' })
    );
  });

  it('an observer CAN delete their own Staffroom post', async () => {
    const db = staffContext(testEnv, 'observer-1', 'school-A', 'observer');
    await assertSucceeds(deleteDoc(doc(db, 'schools/school-A/staffroom/observer-post')));
  });
});
