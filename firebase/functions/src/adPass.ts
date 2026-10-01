// Ad passes: a rewarded ad, verified by Google's AdMob SERVER-SIDE, earns one
// pass that pays for exactly one non-marking AI generation.
//
// WHY SERVER-SIDE VERIFICATION IS NON-NEGOTIABLE: the phone can only say "I
// watched an ad" — and a phone (or a tampered app, or the stub ad service that
// currently reports every ad as watched instantly) can say that for free,
// forever. AdMob's server-side verification (SSV) has Google's own servers call
// OUR endpoint after a genuine, completed rewarded ad, signed with Google's
// private key. Only that signed callback can create a pass.
//
// Setup this needs (none of it code): an AdMob account and app, a rewarded ad
// unit with SSV enabled and its callback URL pointed at the `admobRewardCallback`
// function, and a real ad SDK in the app that sets the Firebase uid as the SSV
// user id. Until then no pass can ever be created, and the feature is off
// (config `adPasses.enabled` is false).
import { createVerify } from "node:crypto";
import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";
import { hashId, type MarkingCreditsConfig } from "./credits";
import { loadCreditsConfig } from "./markingBilling";

export const ADMOB_VERIFIER_KEYS_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json";
/** keyId -> PEM public key. */
export type AdmobKeys = Record<string, string>;

/** Parse AdMob's published verifier-keys document. */
export function parseVerifierKeys(raw: unknown): AdmobKeys {
  const out: AdmobKeys = {};
  const keys = (raw as { keys?: unknown } | null)?.keys;
  if (!Array.isArray(keys)) return out;
  for (const k of keys) {
    const id = (k as { keyId?: unknown })?.keyId;
    const pem = (k as { pem?: unknown })?.pem;
    if ((typeof id === "number" || typeof id === "string") && typeof pem === "string") out[String(id)] = pem;
  }
  return out;
}

export interface AdmobRewardParams {
  uid: string;
  transactionId: string;
  timestampMs: number | null;
  adUnit: string | null;
}

export type SsvResult = { ok: true; params: AdmobRewardParams } | { ok: false; reason: string };

const b64urlToBuffer = (s: string): Buffer => Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");

/**
 * Verify one AdMob SSV callback from its RAW query string. Per Google's spec
 * the signed message is the query string up to (not including) "&signature=",
 * and the signature is URL-safe base64 of an ECDSA/SHA-256 DER signature.
 * Pure — keys are passed in.
 */
export function verifyAdmobCallback(rawQuery: string, keys: AdmobKeys): SsvResult {
  const q = rawQuery.startsWith("?") ? rawQuery.slice(1) : rawQuery;
  const cut = q.indexOf("&signature=");
  if (cut < 0) return { ok: false, reason: "missing signature" };
  const message = q.slice(0, cut);
  const params = new URLSearchParams(q);
  const signature = params.get("signature");
  const keyId = params.get("key_id");
  if (!signature || !keyId) return { ok: false, reason: "missing signature or key_id" };
  const pem = keys[keyId];
  if (!pem) return { ok: false, reason: "unknown key_id" };

  let valid = false;
  try {
    valid = createVerify("SHA256").update(message).verify(pem, b64urlToBuffer(signature));
  } catch {
    valid = false;
  }
  if (!valid) return { ok: false, reason: "bad signature" };

  const uid = params.get("user_id");
  const transactionId = params.get("transaction_id");
  if (!uid || !transactionId) return { ok: false, reason: "missing user_id or transaction_id" };
  const ts = Number(params.get("timestamp"));
  return { ok: true, params: { uid, transactionId, timestampMs: Number.isFinite(ts) && ts > 0 ? ts : null, adUnit: params.get("ad_unit") } };
}

let keyCache: { keys: AdmobKeys; atMs: number } | null = null;
const KEY_TTL_MS = 24 * 60 * 60 * 1000;

/** Google's current verifier keys, cached a day; refetched once if a callback names a key we don't have. */
export async function loadAdmobKeys(nowMs: number, fetchFn: typeof fetch = fetch, forceRefresh = false): Promise<AdmobKeys> {
  if (!forceRefresh && keyCache && nowMs - keyCache.atMs < KEY_TTL_MS) return keyCache.keys;
  const res = await fetchFn(ADMOB_VERIFIER_KEYS_URL);
  if (!res.ok) throw new Error(`AdMob verifier keys HTTP ${res.status}`);
  const keys = parseVerifierKeys(await res.json());
  if (Object.keys(keys).length === 0) throw new Error("AdMob verifier keys document was empty");
  keyCache = { keys, atMs: nowMs };
  return keys;
}

export function resetAdmobKeyCache(): void {
  keyCache = null;
}

const CAT_OFFSET_MS = 2 * 60 * 60 * 1000;
/** Zambian calendar day, e.g. "2026-09-19" — the per-day cap resets on it. */
export function dayKeyCAT(nowMs: number): string {
  return new Date(nowMs + CAT_OFFSET_MS).toISOString().slice(0, 10);
}

export interface GrantResult {
  granted: boolean;
  reason: "granted" | "duplicate" | "disabled" | "daily-cap";
  passId: string;
}

/**
 * Turn a VERIFIED ad callback into a pass. Idempotent per AdMob transaction id
 * (Google retries callbacks), capped per teacher per day, and a no-op while ad
 * passes are switched off in the config.
 */
export async function grantAdPass(
  db: Firestore,
  a: { uid: string; transactionId: string; cfg: MarkingCreditsConfig; nowMs: number }
): Promise<GrantResult> {
  const passId = hashId(`admob:${a.transactionId}`);
  if (!a.cfg.adPasses.enabled) return { granted: false, reason: "disabled", passId };

  const passRef = db.collection("adPasses").doc(passId);
  const counterRef = db.collection("adPassCounters").doc(hashId(`${a.uid}:${dayKeyCAT(a.nowMs)}`));
  return db.runTransaction(async (tx) => {
    if ((await tx.get(passRef)).exists) return { granted: false, reason: "duplicate" as const, passId };
    const count = Number((await tx.get(counterRef)).data()?.count ?? 0);
    if (count >= a.cfg.adPasses.perDayCap) {
      // Remember the transaction so a retried callback doesn't re-evaluate it.
      tx.set(passRef, { uid: a.uid, used: true, capped: true, createdAtMs: a.nowMs, expiresAtMs: 0 });
      return { granted: false, reason: "daily-cap" as const, passId };
    }
    tx.set(passRef, {
      uid: a.uid, used: false, capped: false, createdAtMs: a.nowMs,
      expiresAtMs: a.nowMs + a.cfg.adPasses.ttlHours * 60 * 60 * 1000,
      day: dayKeyCAT(a.nowMs), at: Timestamp.fromMillis(a.nowMs),
    });
    tx.set(counterRef, { uid: a.uid, day: dayKeyCAT(a.nowMs), count: count + 1 }, { merge: true });
    return { granted: true, reason: "granted" as const, passId };
  });
}

/**
 * The whole SSV callback, minus HTTP plumbing: verify Google's signature, then
 * mint the pass. Returns the HTTP status/body to send. Google retries on
 * non-200, so a duplicate or a capped/disabled callback is still a 200 (it is
 * "handled" — retrying can't change the outcome); only an unverifiable
 * request is refused.
 */
export async function handleAdmobCallback(
  db: Firestore,
  rawQuery: string,
  nowMs: number,
  deps: { fetchFn?: typeof fetch } = {}
): Promise<{ status: number; body: string }> {
  let keys: AdmobKeys;
  try {
    keys = await loadAdmobKeys(nowMs, deps.fetchFn);
  } catch (err) {
    console.error("handleAdmobCallback: could not load AdMob verifier keys", err);
    return { status: 503, body: "verifier keys unavailable" }; // Google will retry
  }
  let result = verifyAdmobCallback(rawQuery, keys);
  if (!result.ok && result.reason === "unknown key_id") {
    // Google rotates keys; refetch once before treating it as forged.
    try {
      keys = await loadAdmobKeys(nowMs, deps.fetchFn, true);
      result = verifyAdmobCallback(rawQuery, keys);
    } catch {
      return { status: 503, body: "verifier keys unavailable" };
    }
  }
  if (!result.ok) {
    console.warn(`handleAdmobCallback: rejected (${result.reason})`);
    return { status: 403, body: "rejected" };
  }
  const cfg = await loadCreditsConfig(db, nowMs);
  const grant = await grantAdPass(db, { uid: result.params.uid, transactionId: result.params.transactionId, cfg, nowMs });
  return { status: 200, body: grant.reason };
}
