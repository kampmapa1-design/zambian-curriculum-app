import 'dart:io';
import 'dart:ui' as ui;

/// Flags a captured script page that looks like the same physical page as
/// the one captured right before it (2026-09-10, per explicit request:
/// during cohort capture, "in case the same page of a script is captured
/// more than once, the app should flag it for removal by the user if
/// they so choose, should they choose not to remove it the processing of
/// the batch... must be able to still proceed"). A real, if easy, mistake
/// with [enableAutoCapture] on: the camera can fire again on the same
/// page before a teacher has turned to the next one.
///
/// Uses a classic average-hash (aHash) — resize to a tiny 8x8 greyscale
/// thumbnail, then one bit per pixel for "brighter than this thumbnail's
/// own mean" — computed entirely with Flutter's own `dart:ui` decoding
/// (no new package dependency; this is the same machinery
/// `Image.file`/`Image.memory` already use under the hood to decode a
/// JPEG). Deliberately coarse: it's meant to catch "this is obviously the
/// same page again," not to be a general perceptual-hash library — a
/// small hamming-distance threshold on a coarse 64-bit fingerprint is
/// tolerant of the lighting/angle/focus differences between two real
/// photos of the same page, while still telling two genuinely different
/// pages apart.
///
/// Hashes are [BigInt], not a plain [int] — a real bug caught by this
/// class's own scratch test: the 64th hash bit collides with Dart native
/// `int`'s own sign bit, which silently corrupted both `toRadixString`
/// output and the hamming-distance count for any image whose hash used
/// that bit. [BigInt] has no such bit, at the cost of nothing that
/// matters here (this runs once per captured page, not in a hot loop).
///
/// Known, disclosed edge case (also found via this class's own scratch
/// test): a perfectly flat/solid-colour image always hashes to 0, since
/// every pixel equals that image's own mean exactly — so two different
/// flat colours can't be told apart this way. Never an issue for a real
/// photographed script page (ink, paper grain, and real-world lighting
/// always give it genuine texture/variance), but a device error that
/// produces a truly blank capture (e.g. a lens fully obstructed) would
/// hash the same as any other blank capture — an acceptable, disclosed
/// limitation given what this is actually for, not something worth a
/// heavier algorithm to fix.
class DuplicatePageDetector {
  static const _hashSize = 8; // 8x8 = 64 bits.

  /// A 64-bit average-hash fingerprint for [imageFile]'s visual content.
  Future<BigInt> computeHash(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: _hashSize, targetHeight: _hashSize);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return BigInt.zero;
      final data = byteData.buffer.asUint8List();

      final luminance = <int>[];
      for (var i = 0; i + 2 < data.length; i += 4) {
        luminance.add((data[i] + data[i + 1] + data[i + 2]) ~/ 3);
      }
      if (luminance.isEmpty) return BigInt.zero;
      final mean = luminance.reduce((a, b) => a + b) / luminance.length;

      var hash = BigInt.zero;
      for (var i = 0; i < luminance.length && i < 64; i++) {
        if (luminance[i] > mean) hash |= (BigInt.one << i);
      }
      return hash;
    } finally {
      image.dispose();
    }
  }

  /// Number of differing bits between two hashes — 0 means visually
  /// identical at this coarse resolution, 64 means completely different.
  int hammingDistance(BigInt a, BigInt b) => (a ^ b).toRadixString(2).replaceAll('0', '').length;

  /// True when [a] and [b] look like the same physical page — tuned
  /// loosely (6 of 64 bits, ~9%) so two real photos of the same page
  /// (slightly different angle/lighting/focus between shots) still match,
  /// while two genuinely different pages of real, differently-laid-out
  /// text don't.
  bool looksLikeDuplicate(BigInt a, BigInt b, {int threshold = 6}) => hammingDistance(a, b) <= threshold;
}
