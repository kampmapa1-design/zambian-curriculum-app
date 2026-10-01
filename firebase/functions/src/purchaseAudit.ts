// Audit trail, abuse flags and rate limiting for the purchase pipeline
// (Stage 4e/4f). If a customer disputes a charge or credits go missing, this is
// what answers "what happened?" - every step of a purchase is written here as it
// happens, rather than reconstructed later from partial logs.
//
// RULES: the audit log is best-effort (a failed log write must never fail a real
// purchase - it is reported to the console instead), it is server-only (see
// firestore.rules), and it NEVER contains a raw purchase token: purchases are
// identified by `purchaseKey`, a one-way hash of the token.
import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";
import { hashId } from "./credits";

export interface AuditEntry {
  /** What happened, e.g. "token_received", "verified", "credited", "ack_sent", "voided_reversal". */
  step: string;
  outcome?: "ok" | "refused" | "error" | "info";
  uid?: string | null;
  purchaseKey?: string | null;
  productId?: string | null;
  orderId?: string | null;
  detail?: Record<string, unknown>;
  nowMs: number;
}

// Anything that even looks like a token is dropped from log detail, whoever passes it.
const FORBIDDEN_KEYS = /^(purchase)?token$/i;

function cleanDetail(d: Record<string, unknown> | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(d ?? {})) {
    if (FORBIDDEN_KEYS.test(k)) continue;
    if (v === undefined) continue;
    out[k] = typeof v === "string" && v.length > 300 ? `${v.slice(0, 300)}…` : v;
  }
  return out;
}

/** Write one audit line. Never throws. */
export async function auditPurchase(db: Firestore, e: AuditEntry): Promise<void> {
  try {
    await db.collection("purchaseAuditLog").add({
      step: e.step,
      outcome: e.outcome ?? "info",
      uid: e.uid ?? null,
      purchaseKey: e.purchaseKey ?? null,
      productId: e.productId ?? null,
      orderId: e.orderId ?? null,
      detail: cleanDetail(e.detail),
      atMs: e.nowMs,
      at: Timestamp.fromMillis(e.nowMs),
    });
  } catch (err) {
    console.error(`PURCHASE_AUDIT_WRITE_FAILED step=${e.step} key=${e.purchaseKey ?? "-"}`, err);
  }
}

export type AnomalyType =
  | "rate_high"
  | "token_replay_other_account"
  | "account_binding_mismatch"
  | "product_mismatch"
  | "order_product_mismatch"
  | "price_underpaid"
  | "price_overpaid"
  | "price_unverified"
  | "purchase_refunded_before_credit"
  | "refund_spent_credits"
  | "account_blocked"
  | "partial_refund_manual_review"
  | "acknowledgement_failing"
  | "blocked_account_purchase_attempt";

/** Record something worth a human's attention. Flags - it never blocks by itself. Never throws. */
export async function flagPurchaseAnomaly(
  db: Firestore,
  a: { type: AnomalyType; uid?: string | null; purchaseKey?: string | null; detail?: Record<string, unknown>; nowMs: number }
): Promise<void> {
  try {
    await db.collection("purchaseAnomalies").add({
      type: a.type, status: "open", uid: a.uid ?? null, purchaseKey: a.purchaseKey ?? null,
      detail: cleanDetail(a.detail), atMs: a.nowMs, at: Timestamp.fromMillis(a.nowMs),
    });
  } catch (err) {
    console.error(`PURCHASE_ANOMALY_WRITE_FAILED type=${a.type}`, err);
  }
  await auditPurchase(db, { step: "anomaly", outcome: "info", uid: a.uid, purchaseKey: a.purchaseKey, detail: { type: a.type, ...a.detail }, nowMs: a.nowMs });
}

/** Verification calls per account per window. Flagged well before blocked; the block only protects Google's API quota. */
export const PURCHASE_RATE = { windowMs: 10 * 60 * 1000, flagAt: 8, blockAt: 40 } as const;

export interface RateResult {
  count: number;
  /** True on the attempt that first crosses the flag threshold in this window (so one flag per window, not one per call). */
  newlyFlagged: boolean;
  /** Far above any honest use: refuse this call. */
  blocked: boolean;
}

/** Count one verification attempt for [uid] in the current 10-minute window. */
export async function registerPurchaseAttempt(db: Firestore, uid: string, nowMs: number): Promise<RateResult> {
  const bucket = Math.floor(nowMs / PURCHASE_RATE.windowMs);
  const ref = db.collection("purchaseRate").doc(hashId(`${uid}:${bucket}`));
  return db.runTransaction(async (tx) => {
    const count = Number((await tx.get(ref)).data()?.count ?? 0) + 1;
    tx.set(ref, { uid, bucket, count, updatedAtMs: nowMs });
    return { count, newlyFlagged: count === PURCHASE_RATE.flagAt, blocked: count > PURCHASE_RATE.blockAt };
  });
}
