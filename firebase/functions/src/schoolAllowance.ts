// Included AI usage for subscribed (Gold / Institutional) schools.
//
// Owner's decision (2026-09-19): timetable creation is part of a Gold or
// Institutional subscription, but only up to $1 of real AI cost per school per
// month. Beyond that, further timetable uses are charged in credits (to the
// teacher making the request - there is no school wallet). A school without a
// Gold-or-higher plan gets no timetable access at all; that is enforced by the
// timetable functions themselves (schoolMeetsTimetableTier) and is unchanged.
//
// The measure is the REAL token cost of the school's timetable Gemini calls,
// taken from the same tracking that feeds the owner finance screen, summed per
// Zambian calendar month. It is recorded whether or not charging is switched on,
// so the figures exist before enforcement starts.
import type { Firestore } from "firebase-admin/firestore";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { hashId, periodKeyCAT } from "./credits";

export interface SchoolAllowanceOption {
  /** Allowance group, a key of `cfg.schoolAllowancesUsd` (e.g. "timetable"). */
  group: string;
  /** Pull the school id out of the request data (undefined = not a school request; no allowance applies). */
  schoolId: (data: unknown) => string | undefined;
}

/** The four school-network timetable functions share one allowance. */
export const SCHOOL_TIMETABLE_ALLOWANCE: SchoolAllowanceOption = {
  group: "timetable",
  schoolId: (data) => {
    const id = (data as { schoolId?: unknown } | null | undefined)?.schoolId;
    return typeof id === "string" && id.length > 0 && id.length <= 200 ? id : undefined;
  },
};

const docRef = (db: Firestore, schoolId: string, nowMs: number) =>
  db.collection("schoolAiUsage").doc(hashId(`${schoolId}:${periodKeyCAT(nowMs)}`));

/** USD of this group's AI cost the school has used so far this month. */
export async function readSchoolUsageUsd(db: Firestore, schoolId: string, group: string, nowMs: number): Promise<number> {
  const v = (await docRef(db, schoolId, nowMs).get()).data()?.groups?.[group]?.costUsd;
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}

/** Add measured cost to the school's usage for this month (atomic increments). */
export async function addSchoolUsageUsd(db: Firestore, schoolId: string, group: string, nowMs: number, usd: number): Promise<void> {
  if (!(usd > 0)) return;
  await docRef(db, schoolId, nowMs).set(
    {
      schoolId,
      period: periodKeyCAT(nowMs),
      groups: { [group]: { costUsd: FieldValue.increment(usd), requests: FieldValue.increment(1) } },
      updatedAt: Timestamp.fromMillis(nowMs),
    },
    { merge: true }
  );
}

/**
 * Is this use still inside the included allowance? Decided BEFORE the use, on
 * what has been spent so far: the use that crosses the line is still included,
 * and the ones after it are charged ("charged if they spend more than $1").
 */
export const isWithinAllowance = (usedUsd: number, allowanceUsd: number): boolean => allowanceUsd > 0 && usedUsd < allowanceUsd;
