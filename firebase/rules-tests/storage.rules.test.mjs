// Automated security-rules test suite for firebase/storage.rules
// (school logo path, plus — added 2026-09-18 — the Cloud Backup path
// backups/{uid}/; the other paths, teacher_submissions/ and
// photo_batches/, are covered implicitly by "allow read,write: if false"
// / uid-segment checks that mirror patterns already exercised in the
// Firestore suite; the school logo path is the one with a role-gated
// write, matching Scenario 7 of the verification brief). backups/{uid}/
// is tested explicitly because unlike photo_batches it ALLOWS client
// reads — so "one teacher can never read or overwrite another teacher's
// backup" is a property worth pinning down, not assuming. The rule's
// 250MB size cap is deliberately not tested here: exercising it needs a
// >250MB upload, which is impractical for an emulator unit test.
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
import { ref, uploadBytes, getBytes, deleteObject } from 'firebase/storage';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

const PNG_BYTES = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
// A zip's real magic number (PK\x03\x04) — content doesn't matter to the
// rules (only contentType and size do), but a realistic header keeps the
// fixture honest.
const ZIP_BYTES = new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00]);

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
    // Seed one existing cloud backup for teacher-1 (as their own earlier
    // upload would have left behind).
    await uploadBytes(ref(ctx.storage(), 'backups/teacher-1/existing.zip'), ZIP_BYTES, {
      contentType: 'application/zip',
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

describe('Cloud backups (Storage) — backups/{uid}/', () => {
  const zipMeta = { contentType: 'application/zip' };

  it('the owning teacher CAN upload a zip under their own uid', async () => {
    const storage = testEnv.authenticatedContext('teacher-1').storage();
    await assertSucceeds(uploadBytes(ref(storage, 'backups/teacher-1/new.zip'), ZIP_BYTES, zipMeta));
  });

  it('the owning teacher CAN read their own backup back', async () => {
    const storage = testEnv.authenticatedContext('teacher-1').storage();
    await assertSucceeds(getBytes(ref(storage, 'backups/teacher-1/existing.zip')));
  });

  it('the owning teacher CAN delete their own backup (retention pruning)', async () => {
    const storage = testEnv.authenticatedContext('teacher-1').storage();
    await assertSucceeds(uploadBytes(ref(storage, 'backups/teacher-1/to-delete.zip'), ZIP_BYTES, zipMeta));
    await assertSucceeds(deleteObject(ref(storage, 'backups/teacher-1/to-delete.zip')));
  });

  it('a DIFFERENT signed-in teacher CANNOT read someone else\'s backup', async () => {
    const storage = testEnv.authenticatedContext('teacher-2').storage();
    await assertFails(getBytes(ref(storage, 'backups/teacher-1/existing.zip')));
  });

  it('a DIFFERENT signed-in teacher CANNOT write into someone else\'s backup folder', async () => {
    const storage = testEnv.authenticatedContext('teacher-2').storage();
    await assertFails(uploadBytes(ref(storage, 'backups/teacher-1/planted.zip'), ZIP_BYTES, zipMeta));
  });

  it('a DIFFERENT signed-in teacher CANNOT overwrite or delete someone else\'s existing backup', async () => {
    const storage = testEnv.authenticatedContext('teacher-2').storage();
    await assertFails(uploadBytes(ref(storage, 'backups/teacher-1/existing.zip'), ZIP_BYTES, zipMeta));
    await assertFails(deleteObject(ref(storage, 'backups/teacher-1/existing.zip')));
  });

  it('an unauthenticated caller CANNOT read or write any backup', async () => {
    const storage = testEnv.unauthenticatedContext().storage();
    await assertFails(getBytes(ref(storage, 'backups/teacher-1/existing.zip')));
    await assertFails(uploadBytes(ref(storage, 'backups/teacher-1/anon.zip'), ZIP_BYTES, zipMeta));
  });

  it('the owner CANNOT upload a non-zip file into their own backup folder', async () => {
    const storage = testEnv.authenticatedContext('teacher-1').storage();
    await assertFails(
      uploadBytes(ref(storage, 'backups/teacher-1/not-a-zip.png'), PNG_BYTES, { contentType: 'image/png' })
    );
  });
});
