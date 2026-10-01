// Real, permanent regression coverage for `generateTimetableSchedule` —
// the ONE thing that must never be false is that no teacher or class is
// ever double-booked, plus that the double-period rule, max-daily-load,
// teacher-availability constraints, and locked-assignment preservation
// are all actually respected, and every unresolvable case produces a
// real, named conflict instead of a silently invalid or dropped
// schedule.
//
// This ports scripts/verify_timetable_engine.js (a real, working,
// hand-run verification script written 2026-09-14, kept — see that
// file's own comment) into a proper Jest suite that a real `npm test`
// picks up automatically, rather than something that has to be
// remembered and run by hand against a manual build. Every check below
// is the SAME check that script already made; nothing here is new
// logic, only a different harness for it.
import { generateTimetableSchedule } from "./index";

// The engine's own input interfaces aren't exported (only the function is),
// so derive the type from the function's own signature — needed wherever an
// array of differently-shaped class literals would otherwise be inferred as
// a union TypeScript can't assign to Record<string, string>.
type ClassInput = Parameters<typeof generateTimetableSchedule>[0][number];

function checkDoublePeriods(
  assignments: { classId: string; subjectName: string; day: number; period: number }[],
  classId: string,
  subject: string
): boolean {
  const byDay: Record<number, number[]> = {};
  for (const a of assignments) {
    if (a.classId !== classId || a.subjectName !== subject) continue;
    (byDay[a.day] ??= []).push(a.period);
  }
  for (const day of Object.keys(byDay)) {
    const periods = byDay[Number(day)].sort((x, y) => x - y);
    if (periods.length % 2 !== 0) return false;
    for (let i = 0; i < periods.length; i += 2) {
      if (periods[i + 1] !== periods[i] + 1) return false;
    }
  }
  return true;
}

describe("generateTimetableSchedule", () => {
  test("a small, easily-satisfiable school: no double-booking, double-periods, daily load respected", () => {
    const classes: ClassInput[] = [
      {
        id: "c1",
        classGrade: "Grade 8A",
        subjectNames: ["Math", "English", "Food & Nutrition"],
        subjectTeacherUids: { Math: "tMath", English: "tEng", "Food & Nutrition": "tFood" },
      },
      { id: "c2", classGrade: "Grade 8B", subjectNames: ["Math", "English"], subjectTeacherUids: { Math: "tMath", English: "tEng" } },
    ];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { Math: 6, English: 4, "Food & Nutrition": 3 },
      practicalSubjectsExceptionList: ["Food & Nutrition"],
      maxDailyPeriodsPerTeacher: 6,
    };
    const result = generateTimetableSchedule(classes, config);

    const classSlot = new Set<string>();
    for (const a of result.assignments) {
      const key = `${a.classId}_${a.day}_${a.period}`;
      expect(classSlot.has(key)).toBe(false);
      classSlot.add(key);
    }

    const teacherSlot = new Set<string>();
    for (const a of result.assignments) {
      const key = `${a.teacherUid}_${a.day}_${a.period}`;
      expect(teacherSlot.has(key)).toBe(false);
      teacherSlot.add(key);
    }

    expect(checkDoublePeriods(result.assignments, "c1", "Math")).toBe(true);
    expect(checkDoublePeriods(result.assignments, "c2", "Math")).toBe(true);

    const tMathDaily: Record<number, number> = {};
    for (const a of result.assignments) {
      if (a.teacherUid !== "tMath") continue;
      tMathDaily[a.day] = (tMathDaily[a.day] ?? 0) + 1;
    }
    expect(Object.values(tMathDaily).every((n) => n <= 6)).toBe(true);
    expect(result.conflicts).toHaveLength(0);
  });

  test("a subject with no assigned teacher produces a named conflict, not a crash", () => {
    const classes = [{ id: "c3", classGrade: "Grade 9A", subjectNames: ["Science"], subjectTeacherUids: {} }];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { Science: 5 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
    };
    const result = generateTimetableSchedule(classes, config);
    expect(result.conflicts).toHaveLength(1);
    expect(result.assignments).toHaveLength(0);
  });

  test("odd periods-per-week for a non-practical subject is flagged, and the even part still schedules", () => {
    const classes = [{ id: "c4", classGrade: "Grade 10A", subjectNames: ["History"], subjectTeacherUids: { History: "tHist" } }];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { History: 5 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
    };
    const result = generateTimetableSchedule(classes, config);
    expect(result.conflicts.some((c) => c.description.includes("odd periods-per-week"))).toBe(true);
    // 4 of 5 periods = 2 double blocks = 4 assignments; the odd 5th period is the conflict.
    expect(result.assignments).toHaveLength(4);
  });

  test("an impossible load (too many periods, too few slots) produces real conflicts, not a crash", () => {
    const classes = [{ id: "c5", classGrade: "Grade 11A", subjectNames: ["Overloaded"], subjectTeacherUids: { Overloaded: "tOver" } }];
    const config = {
      periodsPerDay: 2,
      teachingDaysPerWeek: 1,
      subjectDefaults: { Overloaded: 10 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
    };
    const result = generateTimetableSchedule(classes, config);
    expect(result.conflicts.length).toBeGreaterThan(0);
  });

  test("a teacher-availability constraint is actually respected — never placed in an unavailable period", () => {
    const tMathUnavailableAfternoons: string[] = [];
    for (let day = 0; day < 5; day++) {
      for (let period = 4; period < 8; period++) tMathUnavailableAfternoons.push(`${day}_${period}`);
    }
    const classes = [{ id: "c6", classGrade: "Grade 8C", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath2" } }];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { Math: 6 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
      teacherAvailability: { tMath2: tMathUnavailableAfternoons },
    };
    const result = generateTimetableSchedule(classes, config);
    expect(result.assignments.some((a) => a.period >= 4)).toBe(false);
    expect(result.assignments).toHaveLength(6);
  });

  test("a teacher with no availability entry can still be placed in any period (unchanged default behavior)", () => {
    const classes = [{ id: "c7", classGrade: "Grade 8D", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath3" } }];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { Math: 6 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
      teacherAvailability: {},
    };
    const result = generateTimetableSchedule(classes, config);
    expect(result.assignments.some((a) => a.period >= 4)).toBe(true);
    expect(result.assignments).toHaveLength(6);
    expect(result.conflicts).toHaveLength(0);
  });

  test("availability tight enough to make the load infeasible produces a named conflict, and still places what fits", () => {
    const tMath4Unavailable: string[] = [];
    for (let day = 0; day < 5; day++) {
      for (let period = 0; period < 8; period++) {
        if (day === 0 && (period === 0 || period === 1)) continue;
        tMath4Unavailable.push(`${day}_${period}`);
      }
    }
    const classes = [{ id: "c8", classGrade: "Grade 8E", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath4" } }];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { Math: 6 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
      teacherAvailability: { tMath4: tMath4Unavailable },
    };
    const result = generateTimetableSchedule(classes, config);
    expect(result.conflicts.length).toBeGreaterThan(0);
    // The one truly available double-period block (day 0, periods 0-1) still gets placed.
    expect(result.assignments).toHaveLength(2);
  });

  test("a locked assignment survives regeneration completely untouched", () => {
    const classes = [{ id: "c9", classGrade: "Grade 8F", subjectNames: ["Math"], subjectTeacherUids: { Math: "tMath5" } }];
    const config = {
      periodsPerDay: 8,
      teachingDaysPerWeek: 5,
      subjectDefaults: { Math: 6 },
      practicalSubjectsExceptionList: [],
      maxDailyPeriodsPerTeacher: 6,
    };
    const locked = [
      { classId: "c9", className: "Grade 8F", subjectName: "Math", teacherUid: "tMath5", day: 3, period: 6, locked: true },
      { classId: "c9", className: "Grade 8F", subjectName: "Math", teacherUid: "tMath5", day: 3, period: 7, locked: true },
    ];
    const result = generateTimetableSchedule(classes, config, locked);

    for (const l of locked) {
      expect(
        result.assignments.some(
          (a) => a.day === l.day && a.period === l.period && a.classId === l.classId && a.locked === true
        )
      ).toBe(true);
    }
    // 6 periods total, 2 already locked -> only 4 newly placed, 6 in total.
    expect(result.assignments).toHaveLength(6);
    // Nothing else got placed on top of the locked slot.
    expect(result.assignments.filter((a) => a.day === 3 && a.period === 6)).toHaveLength(1);
  });
});
