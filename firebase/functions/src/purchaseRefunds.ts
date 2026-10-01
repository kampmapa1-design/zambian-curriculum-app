// Refunds and voided purchases (Stage 4d): Google Play's Real-time Developer
// Notifications (RTDN) tell us when a purchase is voided, and a daily
// reconciliation against the voided-purchases list catches any notification that
// never arrived.
//
// DECISION (the brief asked for it to be made now): what happens when credits
// from a refunded purchase have already been SPENT?
//   * Credits still unspent are taken back.
//   * The spent part becomes a DEBT on the ledger. The balance itself never goes
//     negative (every part of the app relies on that), and free monthly credits
//     are never touched. The next purchase repays the debt FIRST, so an honest
//     customer with a genuine refund simply gets fewer credits from their next
//     bundle, while someone who buys, spends and refunds gets nothing for free.
//   * Refunds are counted per account: `blockAfterRefunds` inside `windowDays`
//     pause that account's purchases (nothing is charged and nothing acknowledged
//     - Google refunds it) until the owner clears `purchasesBlocked` on the ledger.
//   * The owner is emailed whenever spent credits were refunded or an account is
//     paused. Refunds also reduce the rolling revenue total (a negative event).
//   Rejected alternatives: writing the loss off (repeatable free service),
//   a negative balance (breaks the never-negative rule the whole ledger assumes),
//   blocking on the first refund (punishes genuine mistakes).
//
// Notifications are delivered AT LEAST ONCE and may repeat or arrive out of
// order, so everything here is idempotent per purchase.
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { fromUnits, hashId } from "./credits";
import { loadCreditsConfig } from "./markingBilling";
import { refreshRevenueAndNotify, type RedeemDeps } from "./monetization";
import { PLAY_PACKAGE_NAME } from "./playBilling";
import { auditPurchase, flagPurchaseAnomaly } from "./purchaseAudit";
import { recordRevenueEvent } from "./revenue";

export interface RefundOutcome {
  status: "reversed" | "already_reversed" | "unknown_purchase" | "needs_manual_review";
  /** Credits taken back from the balance. */
  deductedCredits: number;
  /** Credits that could not be taken back (already spent) and are now owed. */
  debtAddedCredits: number;
  /** True if this refund pushed the account over the refund limit. */
  accountBlocked: boolean;
}

const none = (status: RefundOutcome["status"]): RefundOutcome => ({ status, deductedCredits: 0, debtAddedCredits: 0, accountBlocked: false });
const DAY_MS = 24 * 60 * 60 * 1000;

/** Reverse the credits of a voided/refunded purchase. Idempotent. */
export async function reversePurchase(
  deps: RedeemDeps,
  a: { purchaseToken: string; source: "rtdn" | "reconcile"; refundType?: number | null; voidedAtMs?: number | null; reason?: string | number | null }
): Promise<RefundOutcome> {
  const { db, nowMs, notifyOwner } = deps;
  const purchaseKey = hashId(a.purchaseToken);
  const ref = db.collection("processedPurchases").doc(purchaseKey);
  const base = { purchaseKey, nowMs };

  const first = await ref.get();
  const firstData = first.data();
  const uid = (firstData?.ownerId as string | undefined) ?? null;
  const orderId = (firstData?.orderId as string | undefined) ?? null;
  const productId = (firstData?.productId as string | undefined) ?? null;
  const ctx = { ...base, uid, orderId, productId };

  await auditPurchase(db, { ...ctx, step: "void_received", outcome: "info", detail: { source: a.source, refundType: a.refundType ?? null, reason: a.reason ?? null, known: first.exists } });

  if (!first.exists) {
    // Refunded before we ever credited it (or never ours). Nothing to reverse; Google's own state
    // check stops it being credited later, and the record is here if it is ever asked about.
    await auditPurchase(db, { ...ctx, step: "void_unknown_purchase", outcome: "info" });
    return none("unknown_purchase");
  }
  if (a.refundType === 2) {
    // A quantity-based PARTIAL refund: our bundles are quantity 1 so this should not occur; how many units
    // were refunded is not in the notification, so guessing could take back too much or too little.
    await flagPurchaseAnomaly(db, { type: "partial_refund_manual_review", uid, purchaseKey, detail: { orderId, productId }, nowMs });
    await notifyOwner("Smart Teacher: a partial refund needs a manual look", `<p>Order ${orderId ?? "unknown"} (${productId ?? "unknown"}) was partially refunded. Credits were NOT changed automatically.</p>`);
    return none("needs_manual_review");
  }

  const cfg = await loadCreditsConfig(db, nowMs);
  const windowMs = cfg.refundPolicy.windowDays * DAY_MS;

  const result = await db.runTransaction(async (tx) => {
    const pSnap = await tx.get(ref);
    const p = pSnap.data();
    if (!p) return null;
    if (p.status === "voided") return { already: true } as const;
    const ledgerRef = db.collection("creditLedgers").doc(String(p.ownerKey));
    const lSnap = await tx.get(ledgerRef);
    const l = lSnap.data() ?? {};

    const creditedUnits = Number(p.creditedUnits ?? 0) || 0; // what this purchase actually added to the balance
    const repaidUnits = Number(p.debtRepaidUnits ?? 0) || 0; // earlier debt it cleared - unpaid again now
    const purchased = Number(l.purchasedUnits ?? 0) || 0;
    const oldDebt = Math.max(0, Number(l.debtUnits ?? 0) || 0);
    const deduct = Math.min(purchased, creditedUnits);
    const unrecovered = creditedUnits - deduct;
    const newDebt = oldDebt + unrecovered + repaidUnits;

    const recent = (Array.isArray(l.refundTimesMs) ? (l.refundTimesMs as unknown[]) : [])
      .filter((t): t is number => typeof t === "number" && nowMs - t < windowMs);
    const refundTimes = [...recent, nowMs].slice(-20);
    const blockNow = refundTimes.length >= cfg.refundPolicy.blockAfterRefunds;
    const wasBlocked = l.purchasesBlocked === true;

    tx.set(
      ledgerRef,
      {
        purchasedUnits: purchased - deduct, debtUnits: newDebt, refundTimesMs: refundTimes, lastRefundAtMs: nowMs,
        purchasesBlocked: wasBlocked || blockNow, updatedAt: Timestamp.fromMillis(nowMs),
      },
      { merge: true }
    );
    tx.set(ledgerRef.collection("transactions").doc(), {
      type: "refund_reversal", units: -deduct, debtAddedUnits: newDebt - oldDebt, productId: p.productId ?? null, orderId: p.orderId ?? null,
      purchasedAfter: purchased - deduct, at: Timestamp.fromMillis(nowMs),
    });
    tx.set(
      ref,
      {
        status: "voided", voidedAtMs: a.voidedAtMs ?? nowMs, voidSource: a.source,
        reversal: { deductedUnits: deduct, debtAddedUnits: newDebt - oldDebt, accountBlocked: blockNow && !wasBlocked },
        purchaseToken: FieldValue.delete(),
      },
      { merge: true }
    );
    return {
      already: false, deduct, debtAdded: newDebt - oldDebt, newlyBlocked: blockNow && !wasBlocked,
      revenueKwacha: Number(p.revenueKwacha ?? 0) || 0, refundCount: refundTimes.length,
    } as const;
  });

  if (result === null) return none("unknown_purchase");
  if (result.already) {
    await auditPurchase(db, { ...ctx, step: "void_already_processed", outcome: "ok" });
    return none("already_reversed");
  }

  const outcome: RefundOutcome = {
    status: "reversed", deductedCredits: fromUnits(result.deduct), debtAddedCredits: fromUnits(result.debtAdded), accountBlocked: result.newlyBlocked,
  };
  await auditPurchase(db, {
    ...ctx, step: "voided_reversal", outcome: "ok",
    detail: { deductedCredits: outcome.deductedCredits, debtAddedCredits: outcome.debtAddedCredits, refundsInWindow: result.refundCount, accountBlocked: result.newlyBlocked, source: a.source },
  });

  // A refund is negative revenue in the month it happens; the original stays in its own month.
  if (result.revenueKwacha > 0) {
    try {
      await recordRevenueEvent(db, { eventKey: `void:${purchaseKey}`, amountKwacha: -result.revenueKwacha, productId: productId ?? "unknown", atMs: nowMs, orderId, extra: { refund: true } });
      await refreshRevenueAndNotify(deps);
    } catch (err) {
      console.error("reversePurchase: could not record the refund in revenue", err);
    }
  }

  if (result.debtAdded > 0) {
    await flagPurchaseAnomaly(db, { type: "refund_spent_credits", uid, purchaseKey, detail: { debtAddedCredits: outcome.debtAddedCredits, orderId }, nowMs });
    await notifyOwner(
      "Smart Teacher: a refund covered credits that were already spent",
      `<p>Order ${orderId ?? "unknown"} was refunded, but ${outcome.debtAddedCredits} of its credits had already been spent. ` +
        `That amount is now recorded as a debt on the account and will be taken from the customer's next purchase. Credits still unspent (${outcome.deductedCredits}) were taken back.</p>`
    );
  }
  if (result.newlyBlocked) {
    await flagPurchaseAnomaly(db, { type: "account_blocked", uid, purchaseKey, detail: { refundsInWindow: result.refundCount, windowDays: cfg.refundPolicy.windowDays }, nowMs });
    await notifyOwner(
      "Smart Teacher: an account's purchases were paused after repeated refunds",
      `<p>An account reached ${result.refundCount} refunds within ${cfg.refundPolicy.windowDays} days, so buying credits is now paused for it. ` +
        `To clear it, set <code>purchasesBlocked</code> to <code>false</code> on its document in <code>creditLedgers</code> in the Firebase console.</p>`
    );
  }
  return outcome;
}

interface PlayNotification {
  packageName?: unknown;
  testNotification?: unknown;
  voidedPurchaseNotification?: { purchaseToken?: unknown; refundType?: unknown; productType?: unknown; orderId?: unknown };
  oneTimeProductNotification?: { purchaseToken?: unknown; notificationType?: unknown; sku?: unknown };
  pendingRefundReviewNotification?: unknown;
}

/**
 * Handle one Real-time Developer Notification (already decoded from Pub/Sub).
 * Never throws for a bad or irrelevant message - throwing would make Pub/Sub
 * redeliver it forever - it is recorded in the audit log instead.
 */
export async function handlePlayNotification(deps: RedeemDeps, raw: unknown): Promise<{ handled: string }> {
  const { db, nowMs } = deps;
  let n: PlayNotification;
  try {
    n = (typeof raw === "string" ? JSON.parse(raw) : raw) as PlayNotification;
    if (!n || typeof n !== "object") throw new Error("not an object");
  } catch {
    await auditPurchase(db, { step: "rtdn_unreadable", outcome: "error", nowMs });
    return { handled: "unreadable" };
  }
  if (n.packageName !== PLAY_PACKAGE_NAME) {
    await auditPurchase(db, { step: "rtdn_wrong_package", outcome: "refused", detail: { packageName: typeof n.packageName === "string" ? n.packageName : null }, nowMs });
    return { handled: "wrong_package" };
  }
  if (n.testNotification) {
    await auditPurchase(db, { step: "rtdn_test", outcome: "ok", detail: { note: "Google's test notification arrived - the RTDN wiring works" }, nowMs });
    return { handled: "test" };
  }
  const voided = n.voidedPurchaseNotification;
  if (voided) {
    const token = typeof voided.purchaseToken === "string" ? voided.purchaseToken : null;
    if (!token) {
      await auditPurchase(db, { step: "rtdn_void_without_token", outcome: "error", nowMs });
      return { handled: "void_without_token" };
    }
    // productType 1 = subscription: this app sells none.
    if (voided.productType === 1) {
      await auditPurchase(db, { step: "rtdn_subscription_void_ignored", outcome: "info", purchaseKey: hashId(token), nowMs });
      return { handled: "subscription_ignored" };
    }
    const r = await reversePurchase(deps, { purchaseToken: token, source: "rtdn", refundType: typeof voided.refundType === "number" ? voided.refundType : null });
    return { handled: `voided:${r.status}` };
  }
  const oneTime = n.oneTimeProductNotification;
  if (oneTime) {
    const token = typeof oneTime.purchaseToken === "string" ? oneTime.purchaseToken : null;
    // type 2 = CANCELED. A pending purchase being cancelled was never credited; if one WAS credited,
    // treat it like a void rather than leave credits standing on a cancelled purchase.
    if (token && oneTime.notificationType === 2) {
      const known = (await db.collection("processedPurchases").doc(hashId(token)).get()).exists;
      if (known) {
        const r = await reversePurchase(deps, { purchaseToken: token, source: "rtdn", reason: "one_time_product_canceled" });
        return { handled: `canceled:${r.status}` };
      }
    }
    await auditPurchase(db, {
      step: "rtdn_one_time_product", outcome: "info", purchaseKey: token ? hashId(token) : null,
      detail: { notificationType: typeof oneTime.notificationType === "number" ? oneTime.notificationType : null }, nowMs,
    });
    return { handled: "one_time_logged" };
  }
  await auditPurchase(db, { step: "rtdn_other", outcome: "info", detail: { pendingRefundReview: !!n.pendingRefundReviewNotification }, nowMs });
  return { handled: "other" };
}

/**
 * The backstop for missed notifications: list what Google says was voided in the
 * last [days] days and reverse any we still hold as credited. Idempotent, so it
 * is safe to run daily and to overlap with notifications.
 */
export async function reconcileVoidedPurchases(deps: RedeemDeps, days = 7): Promise<{ checked: number; reversed: number; truncated: boolean }> {
  const { verifier, nowMs, db } = deps;
  const { purchases, truncated } = await verifier.listVoidedPurchases(nowMs - days * DAY_MS, nowMs);
  let reversed = 0;
  for (const v of purchases) {
    const r = await reversePurchase(deps, { purchaseToken: v.purchaseToken, source: "reconcile", voidedAtMs: v.voidedTimeMillis, reason: v.voidedReason });
    if (r.status === "reversed") reversed++;
  }
  await auditPurchase(db, { step: "reconcile_done", outcome: truncated ? "error" : "ok", detail: { checked: purchases.length, reversed, truncated, days }, nowMs });
  return { checked: purchases.length, reversed, truncated };
}
