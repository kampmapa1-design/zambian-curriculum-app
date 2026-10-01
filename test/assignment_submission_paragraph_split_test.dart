import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/assignment_submission.dart';
import 'package:zambian_curriculum_app/screens/assignment_submission_screen.dart';
import 'package:zambian_curriculum_app/services/handwriting_document_transcription_service.dart';

/// Assignment Submission paragraph-indentation detection (owner request,
/// 2026-09-28): a clear/consistent indentation signal is already split by
/// the server directly into separate blocks — this only covers the
/// GENUINELY AMBIGUOUS ones the student is asked to confirm, so real
/// coverage here is: confirmed splits happen exactly where confirmed,
/// unconfirmed ones never split anything, and nothing is ever guessed when
/// the anchor text can't actually be found.
void main() {
  group('buildBodyBlocksWithConfirmedSplits', () {
    test('no confirmed splits at all: blocks pass through unchanged', () {
      final blocks = [
        const DocumentBlock(type: DocumentBlockType.heading, text: 'My Essay'),
        const DocumentBlock(type: DocumentBlockType.paragraph, text: 'First point. Second point continues here.'),
      ];
      final result = buildBodyBlocksWithConfirmedSplits(blocks, {});
      expect(result.length, 2);
      expect(result[0].type, AssignmentBodyBlockType.heading);
      expect(result[1].text, 'First point. Second point continues here.');
    });

    test('a confirmed split cuts the block at the real anchor text, into two paragraph blocks', () {
      final blocks = [
        const DocumentBlock(
          type: DocumentBlockType.paragraph,
          text: 'This is the first idea in full. In conclusion the second idea follows.',
        ),
      ];
      final result = buildBodyBlocksWithConfirmedSplits(blocks, {
        0: ['In conclusion the second idea'],
      });
      expect(result.length, 2);
      expect(result[0].type, AssignmentBodyBlockType.paragraph);
      expect(result[0].text, 'This is the first idea in full.');
      expect(result[1].type, AssignmentBodyBlockType.paragraph);
      expect(result[1].text, 'In conclusion the second idea follows.');
    });

    test('a declined (not confirmed) suspected break never splits anything — the caller simply omits it', () {
      // The screen only ever adds an entry to confirmedSplitsByBlock when
      // the student tapped Yes; a "No" answer means nothing is added for
      // that block at all, which is exactly the empty-map case above.
      final blocks = [
        const DocumentBlock(type: DocumentBlockType.paragraph, text: 'One continuous paragraph, never split.'),
      ];
      final result = buildBodyBlocksWithConfirmedSplits(blocks, {});
      expect(result.length, 1);
      expect(result[0].text, 'One continuous paragraph, never split.');
    });

    test("an anchor that can't genuinely be found in the block's own text is never guessed at", () {
      final blocks = [
        const DocumentBlock(type: DocumentBlockType.paragraph, text: 'Real transcribed text only.'),
      ];
      final result = buildBodyBlocksWithConfirmedSplits(blocks, {
        0: ['Text that was never actually transcribed'],
      });
      expect(result.length, 1);
      expect(result[0].text, 'Real transcribed text only.');
    });

    test('multiple confirmed splits in one block produce multiple paragraph blocks, in text order', () {
      final blocks = [
        const DocumentBlock(
          type: DocumentBlockType.paragraph,
          text: 'Part one here. Part two starts now. Part three concludes it.',
        ),
      ];
      final result = buildBodyBlocksWithConfirmedSplits(blocks, {
        0: ['Part three concludes', 'Part two starts'],
      });
      expect(result.length, 3);
      expect(result[0].text, 'Part one here.');
      expect(result[1].text, 'Part two starts now.');
      expect(result[2].text, 'Part three concludes it.');
    });

    test('non-paragraph blocks (heading/bullet/numbered) are never split even with a confirmed entry', () {
      final blocks = [
        const DocumentBlock(type: DocumentBlockType.heading, text: 'Section One Part Two'),
      ];
      final result = buildBodyBlocksWithConfirmedSplits(blocks, {
        0: ['Part Two'],
      });
      // Real defense-in-depth: the screen never asks about a non-paragraph
      // block (the server-side parser already filters these out before
      // they ever reach the confirmation dialog), but this function itself
      // still keeps the original type rather than silently promoting it to
      // 'paragraph' if it were ever called this way regardless.
      expect(result.length, 1);
      expect(result[0].type, AssignmentBodyBlockType.heading);
      expect(result[0].text, 'Section One Part Two');
    });
  });
}
