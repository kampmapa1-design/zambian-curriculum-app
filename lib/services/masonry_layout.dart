/// Bento-grid masonry layout (Stage K of the aesthetics pass, 2026-09-27) —
/// pure placement logic, factored out so it's directly unit-testable
/// without a widget/Firestore harness (the same pattern this codebase
/// already uses for other pure algorithms — see e.g. text_excerpt_matching.dart).
library;

/// How many grid columns a masonry layout should use for a viewport of
/// [width] — a single column below [narrowBreakpoint] (phones, and a
/// narrow browser window — left exactly as a plain single-column list
/// always was, zero behavior change there), 2 up to [wideBreakpoint], 3
/// beyond it (a genuinely wide desktop browser, where a single column of
/// cards wastes most of the available width).
int masonryColumnCountFor(double width, {double narrowBreakpoint = 700, double wideBreakpoint = 1100}) {
  if (width < narrowBreakpoint) return 1;
  if (width < wideBreakpoint) return 2;
  return 3;
}

/// Assigns each of [itemCount] items (by index) to one of [columnCount]
/// columns using a "shortest column first" heuristic: every item goes into
/// whichever column currently has the smallest running total from
/// [estimatedHeight], so real content of varying height (e.g. a class's
/// progress card, which grows with how many subjects that class has)
/// balances across columns instead of every column just getting every
/// Nth item in strict round-robin order regardless of how tall each one
/// actually is.
///
/// Returns one list of item indices per column, in the order items were
/// placed (so within a column, original relative order is kept).
List<List<int>> assignMasonryColumns({
  required int itemCount,
  required int columnCount,
  required double Function(int index) estimatedHeight,
}) {
  assert(columnCount > 0, 'columnCount must be at least 1');
  final columns = List.generate(columnCount, (_) => <int>[]);
  if (columnCount == 1) {
    for (var i = 0; i < itemCount; i++) {
      columns[0].add(i);
    }
    return columns;
  }

  final totals = List.filled(columnCount, 0.0);
  for (var i = 0; i < itemCount; i++) {
    var shortest = 0;
    for (var c = 1; c < columnCount; c++) {
      if (totals[c] < totals[shortest]) shortest = c;
    }
    columns[shortest].add(i);
    totals[shortest] += estimatedHeight(i);
  }
  return columns;
}
