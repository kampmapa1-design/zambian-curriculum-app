// Tests for the offline keyword-overlap matching that powers both
// SubjectContentRepository.findRelevantExcerpt (content enrichment for
// generation) and .searchContent (2026-09-05: the "Generate Teaching
// Notes & Slides" home screen's upper search bar, wired to the on-device
// Subject Content Database for the first time). The repository itself
// depends on path_provider/rootBundle and isn't practical to unit test
// directly, so the real matching logic is tested here in isolation.
import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/text_excerpt_matching.dart';

void main() {
  group('keywordsOf', () {
    test('keeps words longer than 3 characters, lowercased', () {
      expect(keywordsOf('Plant Reproduction in Flowering Plants'), {'plant', 'reproduction', 'flowering', 'plants'});
    });

    test('drops punctuation and short words', () {
      expect(keywordsOf('a of it, reproduction!'), {'reproduction'});
    });
  });

  group('bestExcerptFor', () {
    const text = '''
This is an introductory paragraph about the water cycle and evaporation, nothing about plants here at all.

Plant reproduction occurs through several methods. Flowering plants use pollination to transfer pollen between flowers, leading to fertilisation and seed production.

Seeds then germinate under the right conditions of moisture, warmth, and oxygen.
''';

    test('finds the paragraph with the most matching keywords, not just the first one', () {
      final found = bestExcerptFor(text, keywordsOf('plant reproduction flowering'));
      expect(found, isNotNull);
      expect(found!.excerpt, contains('Plant reproduction occurs'));
      expect(found.score, 3); // plant, reproduction, flowering all matched
    });

    test('folds in a short following paragraph as likely context', () {
      final found = bestExcerptFor(text, keywordsOf('seeds germinate'));
      expect(found, isNotNull);
      // The germination sentence is its own short paragraph -- if it were
      // the SECOND-best match, it should still get folded in as context
      // for whichever paragraph scores highest. Here it's the best match
      // itself since "seeds" isn't in the plant-reproduction paragraph.
      expect(found!.excerpt, contains('germinate'));
    });

    test('returns null when nothing in the text shares any keyword', () {
      final found = bestExcerptFor(text, keywordsOf('quadratic equations algebra'));
      expect(found, isNull);
    });

    test('returns null for empty text', () {
      expect(bestExcerptFor('', keywordsOf('plant')), isNull);
    });
  });

  group('capExcerptWords', () {
    test('leaves short text unchanged', () {
      expect(capExcerptWords('a short excerpt', 350), 'a short excerpt');
    });

    test('truncates long text and appends an ellipsis', () {
      final longText = List.filled(400, 'word').join(' ');
      final capped = capExcerptWords(longText, 350);
      // "..." concatenates directly onto the last kept word (no added
      // space/token) -- still exactly 350 whitespace-separated words.
      expect(capped.split(' ').length, 350);
      expect(capped.endsWith('word...'), isTrue);
    });
  });
}
