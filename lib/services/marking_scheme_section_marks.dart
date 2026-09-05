import 'proportional_allocation.dart';

/// Groups marking-key rows by their TOP-LEVEL question number, treating
/// any lettered/Roman-numeral/parenthesised sub-part that follows the
/// leading number as a CONTINUATION of that same question — real Zambian
/// exam convention, explicit request (2026-09-05): "2(i)", "2(ii)",
/// "2(iii)" are all part of Question 2, not three separate questions, and
/// a section's own printed total (e.g. "Section A = 30 marks") must never
/// be miscounted using the number of LISTED marking-key rows (which
/// include sub-parts) as if each were an independent top-level question.
///
/// Returns the leading digit run found in [label] (e.g. "2" from "2(i)",
/// "2" from "2 ii.", "2" from "Q2a"), or the whole trimmed label
/// unchanged when no leading number is found at all (a lettered-only
/// label, or free-text a teacher typed by hand) — grouping still works
/// correctly in that case, it just falls back to one group per distinct
/// label rather than merging anything.
String topLevelQuestionKey(String label) {
  final match = RegExp(r'(\d+)').firstMatch(label);
  return match?.group(1) ?? label.trim();
}

/// How many DISTINCT top-level questions [labels] actually represents —
/// see [topLevelQuestionKey]. This is the number a teacher means when they
/// look at a real exam paper and say "Section A has 2 questions", not
/// `labels.length` (which would count every Roman-numeral sub-part as its
/// own question).
int countTopLevelQuestions(List<String> labels) => labels.map(topLevelQuestionKey).toSet().length;

/// How a section's confirmed total marks should be distributed across its
/// listed marking-key rows. The two real patterns this app's AI
/// extraction and manual entry both produce, per real Zambian exam
/// convention — explicit request (2026-09-05):
enum SectionMarkingStyle {
  /// Every row in the section is answered and individually graded; marks
  /// are apportioned per row but always SUM to the section's confirmed
  /// total (Section A/B pattern: several questions, some split into
  /// i/ii/iii sub-parts, together always worth the section's stated
  /// total regardless of how many rows that comes to).
  allRowsSumToTotal,

  /// Only ONE row (of several alternative full questions/essays) is
  /// actually answered, and whichever one a candidate chooses is marked
  /// in full out of the section's own confirmed total (Section C/D
  /// pattern: "answer ONE of the following" essay questions, each worth
  /// the section's full stated total on its own).
  oneRowGetsFullTotal,
}

/// Suggests a [SectionMarkingStyle] from a section's own printed answer
/// instructions (e.g. "Answer ALL questions in this section" vs "Answer
/// any ONE of the following THREE questions") — a starting suggestion
/// only, per this app's standing rule of never auto-applying an AI/
/// heuristic judgment call without letting the teacher see and confirm
/// or override it (see MarkingSchemePaperStructureScreen). Defaults to
/// [SectionMarkingStyle.allRowsSumToTotal] (the more common real pattern)
/// when the instructions don't clearly say either way.
SectionMarkingStyle suggestSectionMarkingStyle(String answerInstructions) {
  final text = answerInstructions.toLowerCase();
  final chooseOnePattern = RegExp(r'\bany\s+one\b|\bone\s+of\b|\bchoose\s+one\b|\beither\b|\bone\s+question\b');
  final answerAllPattern = RegExp(r'\ball\s+questions\b|\banswer\s+all\b');
  if (chooseOnePattern.hasMatch(text)) return SectionMarkingStyle.oneRowGetsFullTotal;
  if (answerAllPattern.hasMatch(text)) return SectionMarkingStyle.allRowsSumToTotal;
  return SectionMarkingStyle.allRowsSumToTotal;
}

/// Splits [sectionTotal] across [currentMarks] (one entry per marking-key
/// row, in order) per [style] — see [SectionMarkingStyle]'s own doc
/// comment.
///
/// For [SectionMarkingStyle.allRowsSumToTotal]: splits proportionally to
/// each row's CURRENT mark value, preserving whatever relative weighting
/// a real sourced/AI-extracted marking key already assigned (a longer,
/// more complex sub-part stays worth more than a one-line one) via the
/// same largest-remainder apportionment already trusted elsewhere in this
/// app for exactly this kind of "fixed whole total, split proportionally,
/// must not drift from rounding" problem (see
/// scheme_of_work_calendar_pacing.dart). Falls back to an even split when
/// every row's current mark is the same (including all-zero — e.g. rows
/// with no real per-row marks entered yet). Always sums to EXACTLY
/// [sectionTotal].
///
/// For [SectionMarkingStyle.oneRowGetsFullTotal]: every row gets the FULL
/// [sectionTotal] (not divided) — only one of them will ever actually be
/// answered, and that one is marked in full.
List<double> apportionSectionMarks(
  List<double> currentMarks,
  double sectionTotal,
  SectionMarkingStyle style,
) {
  if (currentMarks.isEmpty) return const [];
  if (style == SectionMarkingStyle.oneRowGetsFullTotal) {
    return [for (var i = 0; i < currentMarks.length; i++) sectionTotal];
  }
  // sectionTotal is a real number a teacher typed (e.g. "30"), but the
  // apportionment machinery works in whole units — round to the nearest
  // whole mark, which matches how every real bundled marking key/exam
  // paper this app has ingested states its totals (whole numbers).
  final wholeTotal = sectionTotal.round();
  final allocated = allocateProportionally(currentMarks, wholeTotal);
  return [for (final m in allocated) m.toDouble()];
}
