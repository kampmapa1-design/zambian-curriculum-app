// Aesthetics pass, Stage K (2026-09-27): the bento-grid masonry placement
// algorithm behind the Admin Web Dashboard's ClassProgressBoard. Pure and
// directly testable (the widget itself needs a live Firestore stream, so —
// same pattern already used elsewhere in this app — the real logic is
// factored out here rather than tested through the widget).
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/masonry_layout.dart';

void main() {
  group('masonryColumnCountFor', () {
    test('a single column below the narrow breakpoint — phones, and a narrow browser, are untouched', () {
      expect(masonryColumnCountFor(0), 1);
      expect(masonryColumnCountFor(375), 1); // a real phone width
      expect(masonryColumnCountFor(699), 1);
    });

    test('2 columns from the narrow breakpoint up to the wide one', () {
      expect(masonryColumnCountFor(700), 2);
      expect(masonryColumnCountFor(900), 2);
      expect(masonryColumnCountFor(1099), 2);
    });

    test('3 columns at and beyond the wide breakpoint — a genuinely wide desktop browser', () {
      expect(masonryColumnCountFor(1100), 3);
      expect(masonryColumnCountFor(2000), 3);
    });

    test('breakpoints are configurable', () {
      expect(masonryColumnCountFor(500, narrowBreakpoint: 400, wideBreakpoint: 800), 2);
      expect(masonryColumnCountFor(900, narrowBreakpoint: 400, wideBreakpoint: 800), 3);
    });
  });

  group('assignMasonryColumns', () {
    test('columnCount 1: every item in the one column, in original order', () {
      final columns = assignMasonryColumns(itemCount: 5, columnCount: 1, estimatedHeight: (_) => 999);
      expect(columns, [
        [0, 1, 2, 3, 4]
      ]);
    });

    test('equal-height items round-robin evenly across columns', () {
      final columns = assignMasonryColumns(itemCount: 6, columnCount: 2, estimatedHeight: (_) => 100);
      expect(columns[0], [0, 2, 4]);
      expect(columns[1], [1, 3, 5]);
    });

    test('a real varying-height case: taller items are balanced, not just alternated', () {
      // Mirrors real classes with different subject counts: one class with
      // many subjects (tall), several with few (short).
      final heights = [300.0, 50.0, 50.0, 50.0, 50.0];
      final columns = assignMasonryColumns(itemCount: 5, columnCount: 2, estimatedHeight: (i) => heights[i]);
      // The one tall item (300) should end up alone-ish in its column,
      // while the four short items pile up in the other — NOT strict
      // round-robin (which would split them 0,2,4 / 1,3 regardless of height).
      final totals = [
        for (final col in columns) col.fold(0.0, (sum, i) => sum + heights[i]),
      ];
      expect((totals[0] - totals[1]).abs(), lessThan(150), reason: 'the two columns end up reasonably balanced by real height, not raw count');
      expect(columns.expand((c) => c).toSet(), {0, 1, 2, 3, 4}, reason: 'every item placed exactly once');
    });

    test('every item appears in exactly one column, regardless of columnCount', () {
      for (final columnCount in [1, 2, 3, 4]) {
        final columns = assignMasonryColumns(itemCount: 10, columnCount: columnCount, estimatedHeight: (i) => (i % 3 + 1) * 10.0);
        final placed = columns.expand((c) => c).toList()..sort();
        expect(placed, List.generate(10, (i) => i));
      }
    });

    test('zero items: every column comes back empty, not an error', () {
      final columns = assignMasonryColumns(itemCount: 0, columnCount: 3, estimatedHeight: (_) => 0);
      expect(columns, [[], [], []]);
    });

    test('a single item always goes in the first column', () {
      final columns = assignMasonryColumns(itemCount: 1, columnCount: 3, estimatedHeight: (_) => 500);
      expect(columns[0], [0]);
      expect(columns[1], isEmpty);
      expect(columns[2], isEmpty);
    });
  });
}
