/// Report Form Pipeline, Stage 8 — a fixed lookup-table comment generator.
/// Deliberately NOT an AI call: this must be instant and perfectly
/// consistent (the same score always produces the exact same comment,
/// forever, on any device, online or offline) — a subject teacher choosing
/// "auto-fill" for one class's comments needs zero variance to trust it.
///
/// Bands are inclusive-lower-bound, evaluated top-down; a score outside
/// [0, 100] still resolves sensibly (anything at/above 75 is "Outstanding",
/// anything below 40 is "More focus needed") rather than returning null.
String reportCommentFor(double score) {
  if (score >= 75) return 'Outstanding performance';
  if (score >= 70) return 'Brilliant performance';
  if (score >= 60) return 'Meritorious performance';
  if (score >= 55) return 'Commendable effort';
  if (score >= 50) return 'Average work';
  if (score >= 40) return 'Must improve';
  return 'More focus needed';
}

/// A short grade code for the report form's "Grade" column — the same 7
/// bands as [reportCommentFor], just abbreviated, so the two columns are
/// always consistent with each other rather than drawn from two different,
/// independently-invented scales.
String reportGradeFor(double score) {
  if (score >= 75) return 'A';
  if (score >= 70) return 'B+';
  if (score >= 60) return 'B';
  if (score >= 55) return 'C+';
  if (score >= 50) return 'C';
  if (score >= 40) return 'D';
  return 'F';
}
