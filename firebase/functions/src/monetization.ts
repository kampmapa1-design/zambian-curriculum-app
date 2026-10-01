// Shared pieces for the purchase pipeline and the owner-finance callables
// (Monetization Stages 4, 5, 7, 8). The purchase verification itself lives in
// purchaseVerification.ts and refunds in purchaseRefunds.ts; this file holds what
// they share plus the owner tools. The onCall wrappers live in index.ts (they
// must be registered after setGlobalOptions); everything testable lives in these
// modules, with the Play verifier and the owner-notification channel injected so
// tests never touch Google or send email.
import { HttpsError } from "firebase-functions/v2/https";
import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";
import { activeBundles, hashId, type BundleDef, type MarkingCreditsConfig } from "./credits";
import { loadCreditsConfig } from "./markingBilling";
import type { PlayVerifier } from "./playBilling";
import {
  buildFinanceSummary,
  fxStatus,
  isOwnerUid,
  loadOwnerSettings,
  updateRevenueSummary,
  type OwnerSettings,
} from "./revenue";

/**
 * The account id attached to a Play purchase at buy time (the client sends
 * this; Play stores it on the purchase and returns it on verification). A
 * hash — never the raw uid — and always 40 hex chars (Play allows up to 64).
 */
export const obfuscatedAccountId = (uid: string): string => hashId(`play-account:${uid}`);

/** A bundle by product id: the active scenario first, then any other — a purchase already paid for must always be honoured. */
export function findBundle(cfg: MarkingCreditsConfig, productId: string): BundleDef | null {
  const active = activeBundles(cfg)[productId];
  if (active) return active;
  for (const scenario of Object.values(cfg.bundles.scenarios)) {
    if (scenario && scenario[productId]) return scenario[productId];
  }
  return null;
}

export interface RedeemDeps {
  db: Firestore;
  verifier: PlayVerifier;
  /** Email/notify the owner. Must not throw for the caller's sake — failures are logged by the implementation. */
  notifyOwner: (subject: string, html: string) => Promise<void>;
  nowMs: number;
}

/** Recompute the rolling total; if this run crossed the VAT threshold, tell the owner (once — the flag is sticky). */
export async function refreshRevenueAndNotify(deps: Pick<RedeemDeps, "db" | "notifyOwner" | "nowMs">, settings?: OwnerSettings) {
  const s = settings ?? (await loadOwnerSettings(deps.db));
  const summary = await updateRevenueSummary(deps.db, deps.nowMs, s.vatThresholdKwacha);
  if (summary.crossedNow) {
    const k = (n: number) => `K${Math.round(n).toLocaleString("en-US")}`;
    await deps.notifyOwner(
      "Smart Teacher: VAT threshold reached",
      `<p>Rolling 12-month bundle revenue is now <b>${k(summary.rolling12mKwacha)}</b>, at or above the configured VAT threshold of <b>${k(summary.thresholdKwacha)}</b>.</p>` +
        `<p>The <code>vatThresholdCrossed</code> flag is now set. To switch bundle sizing to Scenario 2, set <code>bundles.activeScenario</code> in the <code>appConfig/markingCredits</code> document (define <code>scenario2</code> first).</p>` +
        `<p>Note: revenue is counted at the bundles' configured list prices, and the K800,000 threshold figure is unverified — please confirm with your accountant.</p>`
    );
  }
  return summary;
}

// ------------------------------------------------------------------ owner-only tools
export async function requireOwner(db: Firestore, uid: string | undefined): Promise<OwnerSettings> {
  if (!uid) throw new HttpsError("unauthenticated", "Sign in is required.");
  const settings = await loadOwnerSettings(db);
  if (!isOwnerUid(settings, uid)) throw new HttpsError("permission-denied", "This screen is for the app owner only.");
  return settings;
}

export async function getFinanceSummary(db: Firestore, uid: string | undefined, nowMs: number) {
  const settings = await requireOwner(db, uid);
  const [revenueSnap, usageSnap, cfg] = await Promise.all([
    db.collection("ownerData").doc("revenue").get(),
    db.collection("ownerData").doc("usageAgg").get(),
    loadCreditsConfig(db, nowMs),
  ]);
  return buildFinanceSummary({
    settings, revenue: revenueSnap.data(), usageAgg: usageSnap.data() as never, cfg, nowMs,
  });
}

export async function setExchangeRate(db: Firestore, uid: string | undefined, rate: unknown, nowMs: number) {
  const settings = await requireOwner(db, uid);
  if (typeof rate !== "number" || !Number.isFinite(rate) || rate < 1 || rate > 1000) {
    throw new HttpsError("invalid-argument", "Enter the number of kwacha per 1 US dollar (a number between 1 and 1000).");
  }
  const rounded = Math.round(rate * 10000) / 10000;
  const previous = settings.fxUsdToZmw.rate;
  await db.collection("ownerData").doc("settings").set(
    { fxUsdToZmw: { rate: rounded, updatedAtMs: nowMs, updatedAt: Timestamp.fromMillis(nowMs), previousRate: previous } },
    { merge: true }
  );
  return fxStatus({ ...settings, fxUsdToZmw: { rate: rounded, updatedAtMs: nowMs } }, nowMs);
}
