import { generateKeyPairSync, createSign } from "node:crypto";
import { dayKeyCAT, parseVerifierKeys, verifyAdmobCallback } from "./adPass";

// A real ECDSA P-256 key pair standing in for Google's, so the verification
// code is exercised against genuine signatures — the only thing faked is who
// holds the private key.
const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pem = publicKey.export({ type: "spki", format: "pem" }).toString();
const other = generateKeyPairSync("ec", { namedCurve: "P-256" });

const toB64Url = (b: Buffer) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
function signedQuery(message: string, keyId = "1234", key = privateKey): string {
  const sig = createSign("SHA256").update(message).sign(key);
  return `${message}&signature=${toB64Url(sig)}&key_id=${keyId}`;
}
const MSG = "ad_network=5450213213286189855&ad_unit=1234567890&reward_amount=1&reward_item=pass&timestamp=1790000000000&transaction_id=ABCDEF0123456789&user_id=teacher-uid-1";
const keys = { "1234": pem };

describe("verifyAdmobCallback", () => {
  test("a genuine, signed callback is accepted and yields the user and transaction", () => {
    const r = verifyAdmobCallback(signedQuery(MSG), keys);
    expect(r).toEqual({ ok: true, params: { uid: "teacher-uid-1", transactionId: "ABCDEF0123456789", timestampMs: 1790000000000, adUnit: "1234567890" } });
  });

  test("a leading '?' (raw URL form) is tolerated", () => {
    expect(verifyAdmobCallback("?" + signedQuery(MSG), keys).ok).toBe(true);
  });

  test("changing ANY signed field invalidates it — you cannot swap in your own uid or a new transaction id", () => {
    const good = signedQuery(MSG);
    for (const [from, to] of [
      ["user_id=teacher-uid-1", "user_id=someone-else"],
      ["transaction_id=ABCDEF0123456789", "transaction_id=ZZZZZZ"],
      ["reward_amount=1", "reward_amount=9"],
    ]) {
      const r = verifyAdmobCallback(good.replace(from, to), keys);
      expect(r).toMatchObject({ ok: false, reason: "bad signature" });
    }
  });

  test("a signature made with the WRONG private key is rejected (a forged callback)", () => {
    expect(verifyAdmobCallback(signedQuery(MSG, "1234", other.privateKey), keys)).toMatchObject({ ok: false, reason: "bad signature" });
  });

  test("unknown key id, missing signature, garbage signature and empty input are all rejected, never thrown", () => {
    expect(verifyAdmobCallback(signedQuery(MSG, "9999"), keys)).toMatchObject({ ok: false, reason: "unknown key_id" });
    expect(verifyAdmobCallback(MSG, keys)).toMatchObject({ ok: false, reason: "missing signature" });
    expect(verifyAdmobCallback(`${MSG}&signature=!!!notbase64!!!&key_id=1234`, keys)).toMatchObject({ ok: false });
    expect(verifyAdmobCallback("", keys)).toMatchObject({ ok: false });
  });

  test("a validly signed callback with no user or transaction id is rejected", () => {
    const noUser = "ad_network=1&timestamp=1790000000000&transaction_id=T1";
    expect(verifyAdmobCallback(signedQuery(noUser), keys)).toMatchObject({ ok: false, reason: "missing user_id or transaction_id" });
  });
});

describe("parseVerifierKeys", () => {
  test("reads Google's published format (numeric keyId + pem)", () => {
    expect(parseVerifierKeys({ keys: [{ keyId: 3335741209, pem: "PEM-A", base64: "x" }, { keyId: "77", pem: "PEM-B" }] })).toEqual({ "3335741209": "PEM-A", "77": "PEM-B" });
  });
  test("garbage yields no keys (so nothing verifies)", () => {
    for (const raw of [null, {}, { keys: "no" }, { keys: [{ keyId: 1 }] }]) expect(parseVerifierKeys(raw)).toEqual({});
  });
});

describe("dayKeyCAT — the daily cap resets at midnight Zambia time", () => {
  test("22:00 UTC is already the next day in Zambia", () => {
    expect(dayKeyCAT(Date.parse("2026-09-19T21:59:59Z"))).toBe("2026-09-19");
    expect(dayKeyCAT(Date.parse("2026-09-19T22:00:00Z"))).toBe("2026-09-20");
  });
});
