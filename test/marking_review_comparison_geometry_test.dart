import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:zambian_curriculum_app/screens/marking_review_comparison_screen.dart';

/// Marking Reliability Stages 7/8: the pure geometry behind "fit to
/// bounding box" zoom and the highlight outline's on-screen position. Real
/// arithmetic worth pinning down directly, independent of any widget tree.
void main() {
  group('boxToViewportRect', () {
    test('a square image exactly filling a square viewport: the box maps 1:1, no letterboxing', () {
      final rect = boxToViewportRect(
        viewport: const Size(1000, 1000),
        imageSize: const Size(1000, 1000),
        normBox: const Rect.fromLTRB(100, 200, 300, 400),
      );
      expect(rect, const Rect.fromLTRB(100, 200, 300, 400));
    });

    test('a wide image in a narrow (tall) viewport is letterboxed top/bottom, and the box follows that offset', () {
      // image 1000x500 (2:1) fit into a 500x500 viewport -> displayed 500x250, centred vertically (offset 125).
      final rect = boxToViewportRect(
        viewport: const Size(500, 500),
        imageSize: const Size(1000, 500),
        normBox: const Rect.fromLTRB(0, 0, 1000, 1000), // the whole image
      );
      expect(rect.top, closeTo(125, 0.01));
      expect(rect.bottom, closeTo(375, 0.01));
      expect(rect.left, closeTo(0, 0.01));
      expect(rect.right, closeTo(500, 0.01));
    });

    test('a tall image in a wide viewport is letterboxed left/right', () {
      // image 500x1000 (1:2) fit into a 1000x500 viewport -> displayed 250x500, centred horizontally (offset 375).
      final rect = boxToViewportRect(
        viewport: const Size(1000, 500),
        imageSize: const Size(500, 1000),
        normBox: const Rect.fromLTRB(0, 0, 1000, 1000),
      );
      expect(rect.left, closeTo(375, 0.01));
      expect(rect.right, closeTo(625, 0.01));
    });

    test('degenerate input (zero-size viewport/image) never divides by zero — returns Rect.zero', () {
      expect(boxToViewportRect(viewport: Size.zero, imageSize: const Size(10, 10), normBox: const Rect.fromLTRB(0, 0, 100, 100)), Rect.zero);
      expect(boxToViewportRect(viewport: const Size(10, 10), imageSize: Size.zero, normBox: const Rect.fromLTRB(0, 0, 100, 100)), Rect.zero);
    });
  });

  group('fitBoxTransform', () {
    Offset transformPoint(Matrix4 m, Offset p) {
      final v = m.transform3(Vector3(p.dx, p.dy, 0));
      return Offset(v.x, v.y);
    }

    test('a tiny box near a corner is centred in the viewport after transforming', () {
      const viewport = Size(400, 400);
      const imageSize = Size(400, 400); // no letterboxing, simplifies the check
      const box = Rect.fromLTRB(10, 10, 30, 30); // a small box near the top-left
      final m = fitBoxTransform(viewport: viewport, imageSize: imageSize, normBox: box);
      final boxCenterOnScreen = boxToViewportRect(viewport: viewport, imageSize: imageSize, normBox: box).center;
      final mapped = transformPoint(m, boxCenterOnScreen);
      expect(mapped.dx, closeTo(200, 1));
      expect(mapped.dy, closeTo(200, 1));
    });

    test('zoom scale is never below 1x (never zooms OUT past fit-to-view) even for a huge box', () {
      const viewport = Size(400, 400);
      final m = fitBoxTransform(viewport: viewport, imageSize: viewport, normBox: const Rect.fromLTRB(0, 0, 1000, 1000));
      final scale = m.getMaxScaleOnAxis();
      expect(scale, greaterThanOrEqualTo(1.0));
    });

    test('zoom scale is capped at 6x even for an infinitesimally small box', () {
      const viewport = Size(1000, 1000);
      final m = fitBoxTransform(viewport: viewport, imageSize: viewport, normBox: const Rect.fromLTRB(500, 500, 500.01, 500.01));
      expect(m.getMaxScaleOnAxis(), lessThanOrEqualTo(6.0));
    });

    test('degenerate input returns the identity matrix, never NaN/Infinity', () {
      final m = fitBoxTransform(viewport: Size.zero, imageSize: const Size(10, 10), normBox: const Rect.fromLTRB(0, 0, 10, 10));
      expect(m, Matrix4.identity());
    });
  });
}

