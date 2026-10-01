import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/marking_scheme_node.dart';
import 'package:zambian_curriculum_app/services/marking_scheme_checksum.dart';

MarkingSchemeSection _section(String name, List<double> questionMarks) => MarkingSchemeSection(
      name: name,
      questions: [
        for (var i = 0; i < questionMarks.length; i++) MarkingSchemeNode(label: '${i + 1}', marks: questionMarks[i]),
      ],
    );

void main() {
  test('a tree whose real total matches the stated grand total passes', () {
    final result = checkMarkingSchemeChecksum(
      sections: [_section('Section A', [10, 10, 10]), _section('Section B', [20, 20, 20, 10])],
      statedGrandTotal: 100,
    );
    expect(result.matches, isTrue);
    expect(result.sumOfSections, 100);
  });

  test('within tolerance (e.g. an assumed-allocation rounding gap) still passes', () {
    final result = checkMarkingSchemeChecksum(sections: [_section('A', [99])], statedGrandTotal: 100);
    expect(result.matches, isTrue); // 1% gap, well under the 2% tolerance
  });

  test('no stated total at all means nothing to check — always matches', () {
    final result = checkMarkingSchemeChecksum(sections: [_section('A', [10])], statedGrandTotal: null);
    expect(result.matches, isTrue);
    expect(result.difference, 0);
  });

  test('catches the exact original bug pattern: one leaf mismarked far beyond plausible (900 instead of 9)', () {
    // Nine ordinary ~10-mark questions plus one miskeyed to 900 — the real
    // History-paper shape, reproduced here at the marking-SCHEME ingestion
    // level rather than the scoring level.
    final section = _section('A', [10, 10, 10, 10, 10, 10, 10, 10, 900]);
    final result = checkMarkingSchemeChecksum(sections: [section], statedGrandTotal: 100);
    expect(result.matches, isFalse);
    expect(result.sumOfSections, 980);
    expect(result.difference, 880);
  });

  test('a genuinely wrong total is caught even across multiple sections, not just one', () {
    final result = checkMarkingSchemeChecksum(
      sections: [_section('A', [30]), _section('B', [30]), _section('C', [20])],
      statedGrandTotal: 100, // real sum is 80
    );
    expect(result.matches, isFalse);
    expect(result.sumOfSections, 80);
    expect(result.difference, -20);
  });
}
