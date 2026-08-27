import '../models/scheme_of_work.dart';
import '../models/slide_outline.dart';

/// Builds a ~15-slide deck outline from already-generated teaching notes,
/// entirely offline: a title slide, a short introduction (the topic's
/// objectives/competencies), the notes' main points condensed to roughly
/// 60% of their original volume — a stratified sample spread across the
/// whole notes text, not just the first 60%, so later content isn't
/// systematically dropped — and a short conclusion. Matches the
/// intro/60%-of-main-points/conclusion structure requested. Always
/// available, no network required; [SlideOutlineAiService] is an optional
/// richer alternative when online, not a prerequisite for this to work.
///
/// Slide density is content-driven, not slide-count-driven: every slide
/// carries at least [_minBulletsPerSlide] points — a lesson with few points
/// gets few slides rather than slides padded out or left thin. The ~15
/// target is a rough steer for typical-length notes, not a hard quota.
class OfflineSlideOutlineService {
  static const _minBulletsPerSlide = 4;
  static const _targetBulletsPerSlide = 5;

  SlideOutline compose({
    required SchemeOfWorkEntry entry,
    required String notesText,
    required String notesFormat,
  }) {
    // Mutable working copy — intro/conclusion below claim bullets from the
    // front/back of this list (by index, not value, so duplicate-text lines
    // can't accidentally get excluded twice) before the main slides take
    // their 60% sample from what's left.
    final points = _extractPoints(notesText, notesFormat).toList();

    // Introduction: the topic's own syllabus description, not a list of
    // learning objectives — a teacher presenting this slide should be
    // introducing the subject matter itself, not reading out outcomes.
    // Falls back to the notes' own opening lines only when there's no
    // description text on file at all.
    final description = (entry.subTopic?.description ?? entry.topic.description)?.trim();
    final introBullets = (description != null && description.isNotEmpty)
        ? _splitSentences(description).take(4).toList()
        : _takeFront(points, points.length >= 8 ? 3 : (points.length >= 4 ? 2 : 0));

    // Conclusion: a genuine recap drawn from the notes' own closing
    // content, not "learners should now be able to..." — that's objectives
    // language, which belongs in a lesson plan, not a summary slide.
    final conclusionBullets = _takeBack(points, points.length >= 10 ? 4 : (points.length >= 6 ? 2 : 0));
    if (conclusionBullets.isEmpty) {
      conclusionBullets.add('This lesson covered ${entry.title}.');
    }

    final selected = _stratifiedSample(points, 0.6);

    final slides = <Slide>[
      Slide(title: entry.title),
      if (introBullets.isNotEmpty) Slide(title: 'Introduction', bullets: introBullets),
    ];

    final mainSlides = _distribute(selected);
    for (var i = 0; i < mainSlides.length; i++) {
      slides.add(Slide(title: 'Key Points ${i + 1}', bullets: mainSlides[i]));
    }

    slides.add(Slide(title: 'Conclusion', bullets: conclusionBullets));

    return SlideOutline(deckTitle: entry.title, slides: slides);
  }

  /// Removes and returns the first [count] items of [items] (in place).
  List<String> _takeFront(List<String> items, int count) {
    final n = count.clamp(0, items.length);
    final taken = items.take(n).toList();
    items.removeRange(0, n);
    return taken;
  }

  /// Removes and returns the last [count] items of [items] (in place),
  /// preserving their original order.
  List<String> _takeBack(List<String> items, int count) {
    final n = count.clamp(0, items.length);
    final taken = items.sublist(items.length - n);
    items.removeRange(items.length - n, items.length);
    return taken;
  }

  List<String> _splitSentences(String text) {
    return text
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  List<String> _extractPoints(String notesText, String format) {
    final rawLines = notesText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    if (format == 'bullet') {
      return rawLines.map((l) => l.replaceFirst(RegExp(r'^[•\-\*]\s*'), '')).toList();
    }
    final points = <String>[];
    for (final line in rawLines) {
      for (final sentence in line.split(RegExp(r'(?<=[.!?])\s+'))) {
        final trimmed = sentence.trim();
        if (trimmed.isNotEmpty) points.add(trimmed);
      }
    }
    return points;
  }

  /// Picks roughly [fraction] of [items], spread evenly across the whole
  /// list rather than just taking the first N.
  List<String> _stratifiedSample(List<String> items, double fraction) {
    if (items.isEmpty) return items;
    final keepCount = (items.length * fraction).ceil().clamp(1, items.length);
    if (keepCount >= items.length) return items;
    final step = items.length / keepCount;
    return [for (var i = 0; i < keepCount; i++) items[(i * step).floor()]];
  }

  /// Splits [points] into slides with an even spread, never fewer than
  /// [_minBulletsPerSlide] bullets each. If there aren't enough points to
  /// fill even one slide to the minimum, everything goes on a single slide
  /// rather than being padded or dropped.
  List<List<String>> _distribute(List<String> points) {
    if (points.isEmpty) return const [];
    if (points.length < _minBulletsPerSlide) return [points];

    final maxSlidesAtMinimum = points.length ~/ _minBulletsPerSlide;
    final numSlides = (points.length / _targetBulletsPerSlide).round().clamp(1, maxSlidesAtMinimum);

    final base = points.length ~/ numSlides;
    final remainder = points.length % numSlides;
    final result = <List<String>>[];
    var index = 0;
    for (var i = 0; i < numSlides; i++) {
      final count = base + (i < remainder ? 1 : 0);
      result.add(points.sublist(index, index + count));
      index += count;
    }
    return result;
  }
}
