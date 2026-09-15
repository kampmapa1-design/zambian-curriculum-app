// Timetable Generation — a permanent, repeatable verification of
// generateTimetableSchedule against synthetic data (moved here 2026-09-14
// from an ad-hoc scratchpad script written while building Stages 4/3/7 —
// see `npm run verify:timetable`). Checks the ONE thing that must never
// be false: no teacher or class is ever double-booked, plus that the
// double-period rule, max-daily-load, teacher-availability constraints,
// and locked-assignment preservation are all actually respected, and
// every unresolvable case produces a real, named conflict instead of a
// silently invalid or dropped schedule.
//
// Run `npm run build` first (or use `npm run verify:timetable`, which
// does both) — this requires the compiled lib/index.js, not the
// TypeScript source.
const { generateTimetableSchedule } = require("../lib/index.js");

let failures = 0;
function check(label, cond) {
  if (!cond) {
    failures++;
    console.log("FAIL:", label);
  } else {
    console.log("ok:", label);
  }
}

// --- Test 1: a small, easily-satisfiable school ---
const classes1 = [
  { id: "c1", classGrade: "Grade 8A", subjectNames: ["Math", "English", "Food & Nutrition"], subjectTeacherUids: { Math: "tMath", English: "tEng", "Food & Nutrition": "tFood" } },
  { id: "c2", classGrade: "Grade 8B", subjectNames: ["Math", "English"], subjectTeacherUids: { Math: "tMath", English: "tEng" } },
];
const config1 = {
  periodsPerDay: 8,
  teachingDaysPerWeek: 5,
  subjectDefaults: { Math: 6, English: 4, "Food & Nutrition": 3 },
  practicalSubjectsExceptionList: ["Food & Nutrition"],
  maxDailyPeriodsPerTeacher: 6,
};
const result1 = generateTimetableSchedule(classes1, config1);

const classSlot = new Set();
let classDoubleBooked = false;
for (const a of result1.assignments) {
  const key = `${a.classId}_${a.day}_${a.period}`;
  if (classSlot.has(key)) classDoubleBooked = true;
  classSlot.add(key);
}
check("Test1: no class is ever double-booked", !classDoubleBooked);

const teacherSlot = new Set();
let teacherDoubleBooked = false;
for (const a of result1.assignments) {
  const key = `${a.teacherUid}_${a.day}_${a.period}`;
  if (teacherSlot.has(key)) teacherDoubleBooked = true;
  teacherSlot.add(key);
}
check("Test1: no teacher is ever double-booked", !teacherDoubleBooked);

function checkDoublePeriods(assignments, classId, subject) {
  const byDay = {};
  for (const a of assignments) {
    if (a.classId !== classId || a.subjectName !== subject) continue;
    (byDay[a.day] ??= []).push(a.period);
  }
  for (const day of Object.keys(byDay)) {
    const periods = byDay[day].sort((x, y) => x - y);
    if (periods.length % 2 !== 0) return false;
    for (let i = 0; i < periods.length; i += 2) {
      if (periods[i + 1] !== periods[i] + 1) return false;
    }
  }
  return true;
}
check("Test1: Math for c1 is only ever double-periods", checkDoublePeriods(result1.assignments, "c1", "Math"));
check("Test1: Math for c2 is only ever double-periods", checkDoublePeriods(result1.assignments, "c2", "Math"));

const tMathDaily = {};
for (const a of result1.assignments) {
  if (a.teacherUid !== "tMath") continue;
  tMathDaily[a.day] = (tMathDaily[a.day] ?? 0) + 1;
}
check("Test1: tMath never exceeds maxDailyPeriodsPerTeacher (6)", Object.values(tMathDaily).every((n) => n <= 6));
check("Test1: no conflicts expected for this easily-satisfiable case", result1.conflicts.length === 0);
console.log("Test1 assignments:", result1.assignments.length, "conflicts:", result1.conflicts.length);

// --- Test 2: no teacher assigned at all -> must produce a named conflict, not crash ---
const classes2 = [{ id: "c3", classGrade: "Grade 9A", subjectNames: ["Science"], subjectTeacherUids: {} }];
const config2 = { periodsPerDay: 8, teachingDaysPerWeek: 5, subjectDefaults: { Science: 5 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6 };
const result2 = generateTimetableSchedule(classes2, config2);
check("Test2: unassigned-teacher subject produces a conflict, not a crash", result2.conflicts.length === 1 && result2.assignments.length === 0);

// --- Test 3: odd periods/week for a non-practical subject -> flagged ---
const classes3 = [{ id: "c4", classGrade: "Grade 10A", subjectNames: ["History"], subjectTeacherUids: { History: "tHist" } }];
const config3 = { periodsPerDay: 8, teachingDaysPerWeek: 5, subjectDefaults: { History: 5 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6 };
const result3 = generateTimetableSchedule(classes3, config3);
check("Test3: odd periods/week is flagged as a conflict", result3.conflicts.some((c) => c.description.includes("odd periods-per-week")));
check("Test3: still schedules the even part (4 of 5 periods = 2 double blocks = 4 assignments)", result3.assignments.length === 4);

// --- Test 4: impossible case (too many periods, too few slots) -> real conflict, not silent drop ---
const classes4 = [{ id: "c5", classGrade: "Grade 11A", subjectNames: ["Overloaded"], subjectTeacherUids: { Overloaded: "tOver" } }];
const config4 = { periodsPerDay: 2, teachingDaysPerWeek: 1, subjectDefaults: { Overloaded: 10 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6 };
const result4 = generateTimetableSchedule(classes4, config4);
check("Test4: impossible load produces conflicts, not a crash", result4.conflicts.length > 0);

// --- Test 5 (Stage 3): teacher availability constraint is actually respected ---
const tMathUnavailableAfternoons = [];
for (let day = 0; day < 5; day++) {
  for (let period = 4; period < 8; period++) tMathUnavailableAfternoons.push(`${day}_${period}`);
}
const classes5 = [{ id: "c6", classGrade: "Grade 8C", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath2" } }];
const config5 = { periodsPerDay: 8, teachingDaysPerWeek: 5, subjectDefaults: { Math: 6 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6, teacherAvailability: { tMath2: tMathUnavailableAfternoons } };
const result5 = generateTimetableSchedule(classes5, config5);
check("Test5: no assignment placed in a period the teacher marked unavailable", !result5.assignments.some((a) => a.period >= 4));
check("Test5: still schedules the subject within the available morning window", result5.assignments.length === 6);

// --- Test 6 (Stage 3): a teacher with no entry in teacherAvailability behaves exactly as before ---
const classes6 = [{ id: "c7", classGrade: "Grade 8D", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath3" } }];
const config6 = { periodsPerDay: 8, teachingDaysPerWeek: 5, subjectDefaults: { Math: 6 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6, teacherAvailability: {} };
const result6 = generateTimetableSchedule(classes6, config6);
check("Test6: an unconstrained teacher can still be placed in any period, including afternoons", result6.assignments.some((a) => a.period >= 4));
check("Test6: unconstrained teacher gets all 6 periods placed, no conflicts", result6.assignments.length === 6 && result6.conflicts.length === 0);

// --- Test 7 (Stage 3): availability tight enough to force a real conflict ---
const tMath4Unavailable = [];
for (let day = 0; day < 5; day++) {
  for (let period = 0; period < 8; period++) {
    if (day === 0 && (period === 0 || period === 1)) continue;
    tMath4Unavailable.push(`${day}_${period}`);
  }
}
const classes7 = [{ id: "c8", classGrade: "Grade 8E", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath4" } }];
const config7 = { periodsPerDay: 8, teachingDaysPerWeek: 5, subjectDefaults: { Math: 6 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6, teacherAvailability: { tMath4: tMath4Unavailable } };
const result7 = generateTimetableSchedule(classes7, config7);
check("Test7: over-constrained availability produces a named conflict instead of crashing", result7.conflicts.length > 0);
check("Test7: the one truly available double-period block still gets placed", result7.assignments.length === 2);

// --- Test 8 (Stage 7): a locked assignment survives regeneration untouched ---
const classes8 = [{ id: "c9", classGrade: "Grade 8F", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath5" } }];
const config8 = { periodsPerDay: 8, teachingDaysPerWeek: 5, subjectDefaults: { Math: 6 }, practicalSubjectsExceptionList: [], maxDailyPeriodsPerTeacher: 6 };
const locked8 = [
  { classId: "c9", className: "Grade 8F", subjectName: "Math", teacherUid: "tMath5", day: 3, period: 6, locked: true },
  { classId: "c9", className: "Grade 8F", subjectName: "Math", teacherUid: "tMath5", day: 3, period: 7, locked: true },
];
const result8 = generateTimetableSchedule(classes8, config8, locked8);
const stillHasBothLocked = locked8.every((l) =>
  result8.assignments.some((a) => a.day === l.day && a.period === l.period && a.classId === l.classId && a.locked === true)
);
check("Test8: both locked periods survive regeneration unchanged", stillHasBothLocked);
check("Test8: only the remaining 4 periods are newly placed (6 total, 2 locked)", result8.assignments.length === 6);
check("Test8: nothing else got placed on top of the locked slot", result8.assignments.filter((a) => a.day === 3 && a.period === 6).length === 1);

console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
