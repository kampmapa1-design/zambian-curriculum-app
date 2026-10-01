// Buying credits: server-side verification of a Google Play purchase
// (Stage 4a-4c, 4e, 4f). Money is on the line here, so the order of the steps IS
// the design:
//
//   1. validate the request; a real (non-anonymous) sign-in is required
//   2. count the attempt (rate flag / hard limit)          - 4e
//   3. is this account allowed to buy right now?           - refund policy
//   4. ALREADY PROCESSED? -> return success, credit nothing - 4b (before asking Google)
//   5. ask GOOGLE: is it real, is it PURCHASED, is it this product, is it this
//      account's? Never believe the phone.                  - 4a
//   6. read the ORDER and compare the price actually paid    - 4a / 4e
//   7. credit, atomically with recording it as processed     - 4b
//   8. record revenue at what was really paid
//   9. ACKNOWLEDGE to Google (or it refunds in 3 days)       - 4c
//  and every step is written to purchaseAuditLog             - 4f
//
// A purchase that is refused here is NOT acknowledged, so Google refunds it
// automatically within 3 days: the customer is never left having paid for
// credits they didn't get, and we are never left having delivered credits we
// weren't paid for.
import { HttpsError } from "firebase-functions/v2/https";
import { FieldValue } from "firebase-admin/firestore";
import { availableUnits, fromUnits, grantPurchase, hashId, userOwnerKey } from "./credits";
import { loadCreditsConfig } from "./markingBilling";
import { obfuscatedAccountId, findBundle, refreshRevenueAndNotify, type RedeemDeps } from "./monetization";
import { PlayVerificationError, type PlayOrder, type PlayPurchase } from "./playBilling";
import { auditPurchase, flagPurchaseAnomaly, registerPurchaseAttempt, type AnomalyType } from "./purchaseAudit";
import { evaluatePrice, type PriceVerdict } from "./priceCheck";
import { loadOwnerSettings, recordRevenueEvent, toKwacha } from "./revenue";

export interface VerifyInput {
  uid: string;
  isAnonymous: boolean;
  productId: unknown;
  purchaseToken: unknown;
}

export interface VerifyResult {
  /** Credits actually ADDED to the balance (0 for a repeat of an already-processed purchase). */
  creditsGranted: number;
  duplicate: boolean;
  /** Balance in credits after this call. */
  balance: number;
  productId: string;
  /** Whether Google now has this purchase marked acknowledged. */
  acknowledged: boolean;
  /** Credits of this purchase that repaid an earlier refunded purchase (see RefundPolicy). */
  debtRepaidCredits: number;
}

/** Google refunds an unacknowledged purchase after 3 days. */
export const ACK_DEADLINE_MS = 3 * 24 * 60 * 60 * 1000;

const ORDER_REFUNDED_STATES = ["CANCELED", "REFUNDED", "PENDING_REFUND"];

const processedRef = (deps: Pick<RedeemDeps, "db">, key: string) => deps.db.collection("processedPurchases").doc(key);

async function readBalanceCredits(deps: Pick<RedeemDeps, "db">, uid: string): Promise<{ balance: number; blocked: boolean }> {
  const d = (await deps.db.collection("creditLedgers").doc(userOwnerKey(uid)).get()).data();
  const units = availableUnits({
    purchasedUnits: Number(d?.purchasedUnits ?? 0) || 0,
    freeUnits: Number(d?.freeUnits ?? 0) || 0,
    freePeriod: null,
  });
  return { balance: fromUnits(units), blocked: d?.purchasesBlocked === true };
}

/**
 * Tell Google the purchase was delivered (Stage 4c). Records the outcome on the
 * processed-purchase document and in the audit log; on success the stored raw
 * token is deleted (it is only kept so a FAILED acknowledgement can be retried).
 * Never throws. Returns whether the purchase is now acknowledged.
 */
export async function acknowledgePurchase(
  deps: RedeemDeps,
  a: { purchaseKey: string; productId: string; purchaseToken: string; alreadyAcknowledged: boolean; uid: string | null; orderId: string | null }
): Promise<boolean> {
  const { db, verifier, nowMs } = deps;
  const base = { uid: a.uid, purchaseKey: a.purchaseKey, productId: a.productId, orderId: a.orderId, nowMs };
  const markAcknowledged = async (how: string) => {
    await processedRef(deps, a.purchaseKey).set(
      { ackStatus: "acknowledged", ackAtMs: nowMs, ackAttempts: FieldValue.increment(1), purchaseToken: FieldValue.delete() },
      { merge: true }
    );
    await auditPurchase(db, { ...base, step: "ack_sent", outcome: "ok", detail: { how } });
    return true;
  };

  try {
    if (a.alreadyAcknowledged) return await markAcknowledged("already_acknowledged");
    try {
      await verifier.acknowledge(a.productId, a.purchaseToken);
      return await markAcknowledged("acknowledged_now");
    } catch (err) {
      // Google can answer "invalid" simply because it is ALREADY acknowledged (e.g. the client consumed it
      // first). Re-check the real state before treating it as a failure.
      if (err instanceof PlayVerificationError && err.kind === "invalid") {
        const state = await verifier.verify(a.productId, a.purchaseToken);
        if (state.acknowledgementState === 1) return await markAcknowledged("found_already_acknowledged");
      }
      throw err;
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await processedRef(deps, a.purchaseKey)
      .set({ ackStatus: "failed", ackAttempts: FieldValue.increment(1), lastAckError: message.slice(0, 300), lastAckAtMs: nowMs }, { merge: true })
      .catch((e) => console.error("acknowledgePurchase: could not record the failure", e));
    await auditPurchase(db, { ...base, step: "ack_failed", outcome: "error", detail: { error: message } });
    return false;
  }
}

/** Verify a Play purchase and credit it. See the file header for the order of the steps. */
export async function verifyBundlePurchase(deps: RedeemDeps, input: VerifyInput): Promise<VerifyResult> {
  const { db, verifier, notifyOwner, nowMs } = deps;
  const { uid, productId, purchaseToken } = input;

  if (typeof productId !== "string" || !productId || typeof purchaseToken !== "string" || purchaseToken.length < 10 || purchaseToken.length > 2000) {
    await auditPurchase(db, { step: "input_rejected", outcome: "refused", uid, detail: { reason: "product id and purchase token are required" }, nowMs });
    throw new HttpsError("invalid-argument", "A product id and purchase token are required.");
  }
  const purchaseKey = hashId(purchaseToken); // the ONLY identifier of the token that ever reaches a log
  let orderId: string | null = null;
  const log = (step: string, outcome: "ok" | "refused" | "error" | "info", detail?: Record<string, unknown>) =>
    auditPurchase(db, { step, outcome, uid, purchaseKey, productId, orderId, detail, nowMs });
  const flag = (type: AnomalyType, detail?: Record<string, unknown>) => flagPurchaseAnomaly(db, { type, uid, purchaseKey, detail: { productId, orderId, ...detail }, nowMs });
  const refuse = async (step: string, error: HttpsError, detail?: Record<string, unknown>): Promise<never> => {
    await log(step, "refused", { code: error.code, ...detail });
    throw error;
  };

  await log("token_received", "info");

  // 1. A real sign-in: credits live on the account, and an anonymous one is lost on reinstall.
  if (input.isAnonymous) {
    return refuse(
      "anonymous_refused",
      new HttpsError("failed-precondition", "Please sign in with your phone number or email before buying credits, so they are not lost if you reinstall.", { code: "sign_in_required" })
    );
  }

  // 2. Rate: flag early, refuse only far beyond any honest use (which just protects Google's API quota).
  const rate = await registerPurchaseAttempt(db, uid, nowMs);
  if (rate.newlyFlagged) await flag("rate_high", { attemptsInWindow: rate.count });
  if (rate.blocked) {
    return refuse("rate_blocked", new HttpsError("resource-exhausted", "Too many purchase checks in a short time. Please wait a few minutes and try again."), { attemptsInWindow: rate.count });
  }

  const cfg = await loadCreditsConfig(db, nowMs);
  const bundle = findBundle(cfg, productId);
  if (!bundle) return refuse("unknown_product", new HttpsError("invalid-argument", "That product is not a marking-credit bundle."));

  // 3. Has this account been paused after repeated refunds?
  const account = await readBalanceCredits(deps, uid);
  if (account.blocked) {
    await flag("blocked_account_purchase_attempt");
    return refuse(
      "account_blocked",
      new HttpsError(
        "failed-precondition",
        "Buying credits is paused on this account. Nothing has been added, and if you were charged Google will refund you automatically within 3 days.",
        { code: "purchases_blocked" }
      )
    );
  }

  // 4. Idempotency: has this exact purchase already been processed? Checked BEFORE calling Google.
  const prior = await processedRef(deps, purchaseKey).get();
  if (prior.exists) {
    const p = prior.data() ?? {};
    orderId = typeof p.orderId === "string" ? p.orderId : null;
    if (p.ownerId !== uid) {
      // Someone else's purchase token presented by a different account: never credit, and worth knowing about.
      await flag("token_replay_other_account", { originalOwnerHash: hashId(String(p.ownerId ?? "")) });
      return refuse("replay_other_account", new HttpsError("permission-denied", "This purchase belongs to a different account."));
    }
    if (p.status === "voided") {
      return refuse("duplicate_of_refunded", new HttpsError("failed-precondition", "This purchase was refunded, so it can't be credited."));
    }
    await log("duplicate", "ok", { status: p.status, ackStatus: p.ackStatus });
    // Still make sure Google has been told, in case the first attempt's acknowledgement failed.
    let acknowledged = p.ackStatus === "acknowledged";
    if (!acknowledged) {
      acknowledged = await acknowledgePurchase(deps, { purchaseKey, productId, purchaseToken, alreadyAcknowledged: false, uid, orderId });
    }
    return { creditsGranted: 0, duplicate: true, balance: (await readBalanceCredits(deps, uid)).balance, productId, acknowledged, debtRepaidCredits: 0 };
  }

  // 5. Ask Google. Never believe the phone.
  let purchase: PlayPurchase;
  try {
    purchase = await verifier.verify(productId, purchaseToken);
  } catch (err) {
    if (err instanceof PlayVerificationError) {
      console.error(`verifyBundlePurchase: Play verification failed (${err.kind}): ${err.message}`);
      if (err.kind === "invalid") {
        return refuse("verification_invalid", new HttpsError("invalid-argument", "Google Play could not confirm this purchase."), { kind: err.kind });
      }
      if (err.kind === "unauthorized") {
        return refuse(
          "verification_unauthorized",
          new HttpsError("failed-precondition", "Purchases can't be verified yet. Nothing was added to your credits — please try again later.", { code: "verification_unavailable" }),
          { kind: err.kind }
        );
      }
      return refuse("verification_unavailable", new HttpsError("unavailable", "Could not reach Google Play to confirm the purchase. Please try again."), { kind: err.kind });
    }
    throw err;
  }
  orderId = purchase.orderId;
  await log("verified", "ok", {
    purchaseState: purchase.purchaseState, acknowledgementState: purchase.acknowledgementState, consumptionState: purchase.consumptionState,
    purchaseType: purchase.purchaseType, regionCode: purchase.regionCode, quantity: purchase.quantity,
  });

  if (purchase.productId && purchase.productId !== productId) {
    await flag("product_mismatch", { googleProductId: purchase.productId });
    return refuse("product_mismatch", new HttpsError("invalid-argument", "This purchase is for a different product."), { googleProductId: purchase.productId });
  }
  if (purchase.purchaseState === 2) {
    return refuse("purchase_pending", new HttpsError("failed-precondition", "This purchase is still pending. Credits will be added once payment completes.", { code: "purchase_pending" }));
  }
  if (purchase.purchaseState !== 0) {
    return refuse("purchase_not_completed", new HttpsError("failed-precondition", "This purchase was not completed."), { purchaseState: purchase.purchaseState });
  }
  // A token is only redeemable by the account it was bought under (also fails closed when the binding is missing).
  if (purchase.obfuscatedExternalAccountId !== obfuscatedAccountId(uid)) {
    await flag("account_binding_mismatch", { hadBinding: purchase.obfuscatedExternalAccountId !== null });
    return refuse("account_binding_mismatch", new HttpsError("permission-denied", "This purchase belongs to a different account."));
  }

  // 6. The order: what was actually paid, and is it still a live order?
  let order: PlayOrder | null = null;
  if (purchase.orderId) {
    try {
      order = await verifier.getOrder(purchase.orderId);
    } catch (err) {
      await log("order_unavailable", "error", { error: err instanceof Error ? err.message : String(err) });
    }
  }
  if (order && ORDER_REFUNDED_STATES.includes(order.state)) {
    await flag("purchase_refunded_before_credit", { orderState: order.state });
    return refuse("order_refunded", new HttpsError("failed-precondition", "This purchase was refunded, so it can't be credited."), { orderState: order.state });
  }
  if (order && order.lineItemProductIds.length > 0 && !order.lineItemProductIds.includes(productId)) {
    await flag("order_product_mismatch", { orderProducts: order.lineItemProductIds });
    return refuse("order_product_mismatch", new HttpsError("invalid-argument", "This purchase is for a different product."), { orderProducts: order.lineItemProductIds });
  }

  let verdict: PriceVerdict | null = null;
  if (cfg.purchasePolicy.priceCheck !== "off") {
    verdict = evaluatePrice({
      expected: { currency: bundle.listPrice.currency, amount: bundle.listPrice.amount },
      quantity: purchase.quantity, order, purchaseType: purchase.purchaseType, tolerancePercent: cfg.purchasePolicy.tolerancePercent,
    });
    const priceDetail = { status: verdict.status, expected: verdict.expected, observed: verdict.observed, differencePercent: verdict.differencePercent };
    await log("price_checked", "info", priceDetail);
    if (verdict.status === "under") {
      await flag("price_underpaid", priceDetail);
      await notifyOwner(
        "Smart Teacher: a purchase was paid BELOW the bundle price",
        `<p>A purchase of <b>${productId}</b> was paid at ${verdict.observed?.currency} ${verdict.observed?.amount.toFixed(2)}, ` +
          `${verdict.differencePercent}% against the expected ${verdict.expected.currency} ${verdict.expected.amount.toFixed(2)}.</p>` +
          `<p>${cfg.purchasePolicy.priceCheck === "hold" ? "It was <b>not credited and not acknowledged</b>, so Google will refund the customer automatically within 3 days." : "It was credited anyway (price check is set to flag-only)."}</p>` +
          `<p>Most likely the price in Play Console differs from the price in the credits config. Order: ${orderId ?? "unknown"}.</p>`
      );
      if (cfg.purchasePolicy.priceCheck === "hold") {
        return refuse(
          "price_held",
          new HttpsError("failed-precondition", "This purchase is being held for review, so no credits were added. If you were charged, Google will refund you automatically within 3 days.", { code: "purchase_held" }),
          priceDetail
        );
      }
    } else if (verdict.status === "over") {
      await flag("price_overpaid", priceDetail);
    } else if (verdict.status === "unavailable") {
      await flag("price_unverified", { reason: "the order could not be read" });
    }
  }

  // 7. Credit - atomically with recording the purchase as processed (a concurrent duplicate loses the race safely).
  const grant = await grantPurchase(db, {
    ownerKey: userOwnerKey(uid), ownerId: uid, ownerType: "user", purchaseKey, productId,
    credits: bundle.credits * purchase.quantity, orderId, nowMs, purchaseToken,
    extra: {
      quantity: purchase.quantity, purchaseType: purchase.purchaseType, regionCode: purchase.regionCode,
      orderState: order?.state ?? null, isNonPaid: purchase.purchaseType !== null,
      priceStatus: verdict?.status ?? "off", priceObserved: verdict?.observed ?? null, priceExpected: verdict?.expected ?? null,
      developerRevenue: order?.developerRevenue ?? null,
    },
  });
  const after = await readBalanceCredits(deps, uid);
  if (grant.duplicate) {
    await log("duplicate_race", "ok", { note: "another request credited this purchase first" });
  } else {
    await log("credited", "ok", { creditsGranted: grant.creditsGranted, debtRepaidCredits: grant.debtRepaidCredits, balanceAfter: after.balance });
  }

  // 8. Revenue at what was actually paid (test, promo and rewarded purchases are not revenue).
  if (!grant.duplicate && purchase.purchaseType === null) {
    try {
      const settings = await loadOwnerSettings(db);
      const fromOrder = verdict?.observed ? toKwacha(verdict.observed.amount, verdict.observed.currency, settings.fxUsdToZmw.rate) : null;
      const amountKwacha = fromOrder ?? toKwacha(bundle.listPrice.amount * purchase.quantity, bundle.listPrice.currency, settings.fxUsdToZmw.rate);
      if (amountKwacha === null) {
        console.error(`verifyBundlePurchase: unsupported price currency for ${productId}; revenue not recorded`);
      } else {
        await recordRevenueEvent(db, {
          eventKey: purchaseKey, amountKwacha, productId, atMs: purchase.purchaseTimeMillis ?? nowMs, orderId,
          extra: { basis: fromOrder !== null ? "play_order_total" : "list_price", developerRevenue: order?.developerRevenue ?? null },
        });
        await processedRef(deps, purchaseKey).set({ revenueKwacha: amountKwacha }, { merge: true });
        await refreshRevenueAndNotify(deps, settings);
        await log("revenue_recorded", "ok", { amountKwacha, basis: fromOrder !== null ? "play_order_total" : "list_price" });
      }
    } catch (err) {
      // The customer is already credited; revenue tracking failing must not undo or hide that.
      console.error("verifyBundlePurchase: revenue tracking failed after a successful grant", err);
      await log("revenue_failed", "error", { error: err instanceof Error ? err.message : String(err) });
    }
  }

  // 9. Acknowledge - or Google refunds the purchase in 3 days.
  const acknowledged = await acknowledgePurchase(deps, {
    purchaseKey, productId, purchaseToken, alreadyAcknowledged: purchase.acknowledgementState === 1, uid, orderId,
  });

  return { creditsGranted: grant.creditsGranted, duplicate: grant.duplicate, balance: after.balance, productId, acknowledged, debtRepaidCredits: grant.debtRepaidCredits };
}

/** Kept so the app build already in testers' hands (which calls `redeemMarkingBundle`) keeps working. */
export const redeemBundle = verifyBundlePurchase;

/**
 * Retry acknowledgements that failed (or never ran) - the safety net for 4c: an
 * unacknowledged purchase is refunded by Google after 3 days, so a credited
 * purchase must not be left that way. Run on a schedule.
 */
export async function retryPendingAcknowledgements(deps: RedeemDeps): Promise<{ attempted: number; acknowledged: number; expired: number }> {
  const { db, nowMs } = deps;
  const out = { attempted: 0, acknowledged: 0, expired: 0 };
  const seen = new Set<string>();
  for (const status of ["pending", "failed"] as const) {
    const snap = await db.collection("processedPurchases").where("ackStatus", "==", status).limit(200).get();
    for (const doc of snap.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      const p = doc.data();
      if (p.status !== "credited") continue;
      const age = nowMs - Number(p.createdAtMs ?? nowMs);
      if (age < 5 * 60 * 1000) continue; // a request may still be acknowledging it right now
      if (age > ACK_DEADLINE_MS) {
        // Google will already have refunded it. Record that we lost the race, loudly.
        await doc.ref.set({ ackStatus: "expired" }, { merge: true });
        await flagPurchaseAnomaly(db, { type: "acknowledgement_failing", uid: p.ownerId ?? null, purchaseKey: doc.id, detail: { expired: true, ageHours: Math.round(age / 3600000) }, nowMs });
        out.expired++;
        continue;
      }
      if (typeof p.purchaseToken !== "string" || typeof p.productId !== "string") continue;
      out.attempted++;
      const ok = await acknowledgePurchase(deps, {
        purchaseKey: doc.id, productId: p.productId, purchaseToken: p.purchaseToken, alreadyAcknowledged: false, uid: p.ownerId ?? null, orderId: p.orderId ?? null,
      });
      if (ok) {
        out.acknowledged++;
      } else if (age > 24 * 60 * 60 * 1000 && p.ackAlerted !== true) {
        await doc.ref.set({ ackAlerted: true }, { merge: true });
        await flagPurchaseAnomaly(db, { type: "acknowledgement_failing", uid: p.ownerId ?? null, purchaseKey: doc.id, detail: { ageHours: Math.round(age / 3600000) }, nowMs });
        await deps.notifyOwner(
          "Smart Teacher: a purchase still isn't acknowledged",
          `<p>A credited purchase (order ${p.orderId ?? "unknown"}) has failed to acknowledge for over 24 hours. Google refunds an unacknowledged purchase after 3 days, ` +
            `so the customer would then keep their credits while you lose the money. Check the Play API access in <code>docs/MONETIZATION_SETUP.md</code>.</p>`
        );
      }
    }
  }
  return out;
}
