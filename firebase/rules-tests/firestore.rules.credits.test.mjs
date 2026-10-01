// Rules tests for the Monetization collections (added 2026-09-19): a user may
// READ only their own credit ledger and the public pricing config; nobody may
// ever WRITE any of it from a client — that is what stops a user granting
// themselves credits — and owner/revenue/usage/purchase data is fully closed.
import { readFileSync } from 'node:fs';
import { describe, it, before, after } from 'node:test';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc, getDocs, collection, query, where } from 'firebase/firestore';

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'rules-test-credits',
    firestore: {
      rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
      host: 'localhost',
      port: 8089,
    },
  });
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const seeds = [
      ['appConfig/markingCredits', { mode: 'enforced', freeMonthlyCredits: 20 }],
      ['appConfig/somethingElse', { secret: true }],
      ['creditLedgers/user_alice', { purchasedUnits: 5000, freeUnits: 1000 }],
      ['creditLedgers/user_alice/transactions/t1', { type: 'spend', units: -1000 }],
      ['creditLedgers/user_alice/charges/c1', { units: 1000 }],
      ['creditLedgers/user_bob', { purchasedUnits: 9999, freeUnits: 0 }],
      ['creditLedgers/user_bob/transactions/t1', { type: 'purchase', units: 9999 }],
      ['ownerData/settings', { ownerUids: ['owner-uid'] }],
      ['ownerData/revenue', { rolling12mKwacha: 123 }],
      ['ownerData/usageAgg', { engines: {} }],
      ['markingUsage/u1', { uidHash: 'abc' }],
      ['processedPurchases/p1', { ownerKey: 'user_alice', purchaseToken: 'raw-token-must-never-leak' }],
      ['purchaseAuditLog/a1', { step: 'credited' }],
      ['purchaseAnomalies/n1', { type: 'price_underpaid' }],
      ['purchaseRate/r1', { count: 3 }],
      ['revenueEvents/r1', { amountKwacha: 50 }],
      ['featureUsage/f1', { uidHash: 'abc' }],
      ['adPassCounters/c1', { count: 3 }],
      ['adPasses/pass-alice', { uid: 'alice', used: false, expiresAtMs: 9999999999999 }],
      ['adPasses/pass-bob', { uid: 'bob', used: false, expiresAtMs: 9999999999999 }],
      ['personalSubscriptions/alice', { tier: 'gold' }],
      ['personalSubscriptions/bob', { tier: 'basic' }],
      ['system/cdcRefreshGuard', { consecutiveFailures: 2 }],
      ['system/cdcResourcesCache', { resources: [] }],
    ];
    for (const [path, data] of seeds) await setDoc(doc(db, path), data);
  });
});

after(async () => {
  await testEnv.cleanup();
});

const as = (uid) => testEnv.authenticatedContext(uid).firestore();
const signedOut = () => testEnv.unauthenticatedContext().firestore();

describe('appConfig/markingCredits (public pricing config)', () => {
  it('any signed-in user CAN read it', async () => {
    await assertSucceeds(getDoc(doc(as('alice'), 'appConfig/markingCredits')));
  });
  it('a signed-out client CANNOT', async () => {
    await assertFails(getDoc(doc(signedOut(), 'appConfig/markingCredits')));
  });
  it('NOBODY can write it from a client — not even the account being billed', async () => {
    await assertFails(setDoc(doc(as('alice'), 'appConfig/markingCredits'), { mode: 'off' }));
    await assertFails(updateDoc(doc(as('alice'), 'appConfig/markingCredits'), { freeMonthlyCredits: 9999 }));
    await assertFails(deleteDoc(doc(as('alice'), 'appConfig/markingCredits')));
  });
  it('other appConfig documents are NOT exposed by the same rule', async () => {
    await assertFails(getDoc(doc(as('alice'), 'appConfig/somethingElse')));
  });
});

describe('creditLedgers — own ledger read-only', () => {
  it('a user CAN read their own ledger and transaction history', async () => {
    await assertSucceeds(getDoc(doc(as('alice'), 'creditLedgers/user_alice')));
    await assertSucceeds(getDoc(doc(as('alice'), 'creditLedgers/user_alice/transactions/t1')));
    await assertSucceeds(getDocs(collection(as('alice'), 'creditLedgers/user_alice/transactions')));
  });
  it("a user CANNOT read someone else's ledger or history", async () => {
    await assertFails(getDoc(doc(as('alice'), 'creditLedgers/user_bob')));
    await assertFails(getDoc(doc(as('alice'), 'creditLedgers/user_bob/transactions/t1')));
    await assertFails(getDocs(collection(as('alice'), 'creditLedgers/user_bob/transactions')));
  });
  it('a signed-out client CANNOT read any ledger', async () => {
    await assertFails(getDoc(doc(signedOut(), 'creditLedgers/user_alice')));
  });
  it('a user cannot read a ledger by guessing the un-prefixed uid or another key shape', async () => {
    await assertFails(getDoc(doc(as('alice'), 'creditLedgers/alice')));
    await assertFails(getDoc(doc(as('alice'), 'creditLedgers/school_alice')));
  });
  it('a user CANNOT write their own balance — set, update, delete or add history', async () => {
    const db = as('alice');
    await assertFails(setDoc(doc(db, 'creditLedgers/user_alice'), { purchasedUnits: 999999999, freeUnits: 999999999 }));
    await assertFails(updateDoc(doc(db, 'creditLedgers/user_alice'), { purchasedUnits: 999999999 }));
    await assertFails(deleteDoc(doc(db, 'creditLedgers/user_alice')));
    await assertFails(setDoc(doc(db, 'creditLedgers/user_alice/transactions/forged'), { type: 'purchase', units: 999999 }));
    await assertFails(updateDoc(doc(db, 'creditLedgers/user_alice/transactions/t1'), { units: 0 }));
  });
  it('a user cannot create a ledger for a fresh key either', async () => {
    await assertFails(setDoc(doc(as('carol'), 'creditLedgers/user_carol'), { purchasedUnits: 1000000, freeUnits: 0 }));
  });
  it('the internal charge markers are invisible and unwritable — even to the ledger owner', async () => {
    const db = as('alice');
    await assertFails(getDoc(doc(db, 'creditLedgers/user_alice/charges/c1')));
    await assertFails(setDoc(doc(db, 'creditLedgers/user_alice/charges/c1'), { units: 0 }));
    await assertFails(deleteDoc(doc(db, 'creditLedgers/user_alice/charges/c1'))); // deleting a marker would allow a double charge
  });
});

describe('owner / revenue / usage / purchase data — closed to every client', () => {
  const paths = ['ownerData/settings', 'ownerData/revenue', 'ownerData/usageAgg', 'markingUsage/u1', 'processedPurchases/p1', 'purchaseAuditLog/a1', 'purchaseAnomalies/n1', 'purchaseRate/r1', 'revenueEvents/r1', 'featureUsage/f1', 'adPassCounters/c1', 'system/cdcRefreshGuard', 'system/cdcResourcesCache'];
  for (const p of paths) {
    it(`${p}: no read, no write — even for the listed owner uid`, async () => {
      for (const db of [as('alice'), as('owner-uid'), signedOut()]) {
        await assertFails(getDoc(doc(db, p)));
        await assertFails(setDoc(doc(db, p), { x: 1 }));
        await assertFails(deleteDoc(doc(db, p)));
      }
    });
  }
  it('a client cannot make themselves an owner by writing ownerData/settings', async () => {
    await assertFails(setDoc(doc(as('mallory'), 'ownerData/settings'), { ownerUids: ['mallory'] }));
  });
});

describe('adPasses — a teacher can see their own passes, never mint or spend one', () => {
  it('a user CAN read their own pass, and query their own passes', async () => {
    await assertSucceeds(getDoc(doc(as('alice'), 'adPasses/pass-alice')));
    await assertSucceeds(getDocs(query(collection(as('alice'), 'adPasses'), where('uid', '==', 'alice'))));
  });
  it("a user CANNOT read someone else's pass, nor query for another user's", async () => {
    await assertFails(getDoc(doc(as('alice'), 'adPasses/pass-bob')));
    await assertFails(getDocs(query(collection(as('alice'), 'adPasses'), where('uid', '==', 'bob'))));
  });
  it('an unconstrained list of all passes is refused', async () => {
    await assertFails(getDocs(collection(as('alice'), 'adPasses')));
  });
  it('a signed-out client CANNOT read a pass', async () => {
    await assertFails(getDoc(doc(signedOut(), 'adPasses/pass-alice')));
  });
  it('a user CANNOT create a pass for themselves, mark one unused again, or delete one', async () => {
    const db = as('alice');
    await assertFails(setDoc(doc(db, 'adPasses/forged'), { uid: 'alice', used: false, expiresAtMs: 9999999999999 }));
    await assertFails(updateDoc(doc(db, 'adPasses/pass-alice'), { used: false, expiresAtMs: 99999999999999 }));
    await assertFails(deleteDoc(doc(db, 'adPasses/pass-alice')));
  });
});

// Individual-teacher subscriptions (owner decision, 2026-09-28) — a teacher
// may read their own personal tier so the app can show it, but only the
// server (Cloud Functions / manual Console entry, same as `schools/{id}`)
// may ever set one — this is exactly what stops a teacher granting
// themselves Gold access for free.
describe('personalSubscriptions — a teacher can see their own tier, never set one', () => {
  it('a user CAN read their own personal subscription doc', async () => {
    await assertSucceeds(getDoc(doc(as('alice'), 'personalSubscriptions/alice')));
    await assertSucceeds(getDoc(doc(as('bob'), 'personalSubscriptions/bob')));
  });
  it("a user CANNOT read someone else's personal subscription doc", async () => {
    await assertFails(getDoc(doc(as('alice'), 'personalSubscriptions/bob')));
  });
  it('a signed-out client CANNOT read any personal subscription doc', async () => {
    await assertFails(getDoc(doc(signedOut(), 'personalSubscriptions/alice')));
  });
  it('a user CANNOT set, upgrade, or delete their own tier', async () => {
    const db = as('bob');
    await assertFails(setDoc(doc(db, 'personalSubscriptions/bob'), { tier: 'institutional' }));
    await assertFails(updateDoc(doc(db, 'personalSubscriptions/bob'), { tier: 'gold' }));
    await assertFails(deleteDoc(doc(db, 'personalSubscriptions/bob')));
  });
  it('a user CANNOT forge a personal subscription for someone else', async () => {
    await assertFails(setDoc(doc(as('alice'), 'personalSubscriptions/carol'), { tier: 'institutional' }));
  });
});
