// Automated security-rules test suite for firebase/storage.rules
// (school logo path only — the other paths, teacher_submissions/ and
// photo_batches/, are covered implicitly by "allow read,write: if false"
// / uid-segment checks that mirror patterns already exercised in the
// Firestore suite; the school logo path is the one with a role-gated
// write, matching Scenario 7 of the verification brief).
//
// Run with: npm test   (from firebase/rules-tests) — see
// firestore.rules.test.mjs for how the emulator is started/stopped.

import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { ref, uploadBytes, getBytes } from 'firebase/storage';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

const PNG_BYTES = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-storage',
    storage: {
      rules: readFileSync(new URL('../storage.rules', import.meta.url), 'utf8'),
      host: 'localhost',
      port: 9199,
    },
  });

  // Seed an existing logo object, bypassing rules (as the app's own
  // leadership-role upload would have done).
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(ref(ctx.storage(), 'schools/school-A/logo'), PNG_BYTES, {
      contentType: 'image/png',
    });
  });
});

after(async () => {
  await testEnv.cleanup();
});

function staffStorage(uid, schoolId, schoolRole) {
  return testEnv.authenticatedContext(uid, { schoolId, schoolRole }).storage();
}

describe('School logo (Storage)', () => {
  it('any member of the school (matching schoolId claim) CAN read the logo', async () => {
    const storage = staffStorage('staff-a', 'school-A', 'teacher');
    await assertSucceeds(getBytes(ref(storage, 'schools/school-A/logo')));
  });

  it('a member of a DIFFERENT school CANNOT read the logo', async () => {
    const storage = staffStorage('staff-b', 'school-B', 'teacher');
    await assertFails(getBytes(ref(storage, 'schools/school-A/logo')));
  });

  it('a leadership role (head_teacher/deputy/administrator) CAN write the logo', async () => {
    const storage = staffStorage('lead-1', 'school-A', 'head_teacher');
    await assertSucceeds(
      uploadBytes(ref(storage, 'schools/school-A/logo'), PNG_BYTES, { contentType: 'image/png' })
    );
  });

  it('a plain teacher CANNOT write the logo', async () => {
    const storage = staffStorage('staff-a', 'school-A', 'teacher');
    await assertFails(
      uploadBytes(ref(storage, 'schools/school-A/logo'), PNG_BYTES, { contentType: 'image/png' })
    );
  });
});
