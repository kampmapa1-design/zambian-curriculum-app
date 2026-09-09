// A real, permanent regression test (2026-09-10), kept rather than
// deleted as scratch: writing it caught a genuine bug the first time it
// ran — DuplicatePageDetector's hash used a plain Dart `int`, and the
// 64th hash bit collided with `int`'s own native sign bit, silently
// corrupting both `toRadixString` output and the hamming-distance count
// for any image whose hash happened to use that bit (see
// DuplicatePageDetector's own doc comment for the full story; fixed by
// switching to `BigInt`). Verifies the average-hash logic against real
// synthesized images (solid colours, gradients, a checkerboard — decoded
// through the real dart:ui codec path, not hand-computed) rather than
// trusting the algorithm's own reasoning alone.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/duplicate_page_detector.dart';

Future<File> _writeSolidColorPng(String path, int r, int g, int b) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint()..color = ui.Color.fromARGB(255, r, g, b));
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File(path);
  await file.writeAsBytes(byteData!.buffer.asUint8List());
  return file;
}

// A checkerboard, so it's genuinely visually distinct from a solid grey of
// the same overall average brightness — a naive "compare average
// brightness only" implementation would wrongly call these identical.
Future<File> _writeCheckerboardPng(String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  const cell = 8.0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      final isDark = (x + y).isEven;
      canvas.drawRect(
        ui.Rect.fromLTWH(x * cell, y * cell, cell, cell),
        ui.Paint()..color = isDark ? const ui.Color.fromARGB(255, 20, 20, 20) : const ui.Color.fromARGB(255, 235, 235, 235),
      );
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File(path);
  await file.writeAsBytes(byteData!.buffer.asUint8List());
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('same file hashes identically (deterministic, distance 0)', () async {
    final dir = await Directory.systemTemp.createTemp('dup_page_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = await _writeSolidColorPng('${dir.path}/a.png', 30, 30, 30);

    final detector = DuplicatePageDetector();
    final hash1 = await detector.computeHash(file);
    final hash2 = await detector.computeHash(file);

    expect(hash1, hash2);
    expect(detector.hammingDistance(hash1, hash2), 0);
    expect(detector.looksLikeDuplicate(hash1, hash2), isTrue);
  });

  test('a left-to-right gradient and its mirror image do NOT look like duplicates', () async {
    // A real captured page always has some real texture/shading (ink,
    // paper grain, uneven lighting) — a perfectly flat solid colour (used
    // in the other tests here for simplicity) is a degenerate case for
    // ANY average-hash: every pixel equals the image's own mean exactly,
    // so it always hashes to 0 regardless of which flat shade it is. Two
    // opposite gradients are a realistic stand-in for "genuinely different
    // real pages" that isn't degenerate this way.
    final dir = await Directory.systemTemp.createTemp('dup_page_test');
    addTearDown(() => dir.delete(recursive: true));

    Future<File> writeGradient(String path, {required bool reversed}) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      for (var x = 0; x < 8; x++) {
        final shade = reversed ? 255 - (x * 32) : x * 32;
        canvas.drawRect(
          ui.Rect.fromLTWH(x * 8.0, 0, 8, 64),
          ui.Paint()..color = ui.Color.fromARGB(255, shade, shade, shade),
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 64);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File(path);
      await file.writeAsBytes(byteData!.buffer.asUint8List());
      return file;
    }

    final leftDark = await writeGradient('${dir.path}/left_dark.png', reversed: false);
    final rightDark = await writeGradient('${dir.path}/right_dark.png', reversed: true);

    final detector = DuplicatePageDetector();
    final hashA = await detector.computeHash(leftDark);
    final hashB = await detector.computeHash(rightDark);

    expect(detector.looksLikeDuplicate(hashA, hashB), isFalse);
  });

  test('two solid-grey images of the SAME shade look like duplicates (the real "same page twice" case)', () async {
    final dir = await Directory.systemTemp.createTemp('dup_page_test');
    addTearDown(() => dir.delete(recursive: true));
    // Two independently-encoded PNGs of the same flat colour stand in for
    // "two real photos of the same physical page" — different file bytes
    // (a fresh PNG encode each time), same visual content.
    final shot1 = await _writeSolidColorPng('${dir.path}/shot1.png', 180, 180, 180);
    final shot2 = await _writeSolidColorPng('${dir.path}/shot2.png', 180, 180, 180);

    final detector = DuplicatePageDetector();
    final hash1 = await detector.computeHash(shot1);
    final hash2 = await detector.computeHash(shot2);

    expect(detector.looksLikeDuplicate(hash1, hash2), isTrue);
  });

  test('a checkerboard is NOT flagged as a duplicate of a flat grey with the same average brightness', () async {
    final dir = await Directory.systemTemp.createTemp('dup_page_test');
    addTearDown(() => dir.delete(recursive: true));
    final checkerboard = await _writeCheckerboardPng('${dir.path}/checker.png');
    // (20+235)/2 = 127.5 — the same overall average brightness as the
    // checkerboard's own two tones.
    final flatGrey = await _writeSolidColorPng('${dir.path}/flat.png', 127, 127, 127);

    final detector = DuplicatePageDetector();
    final checkerHash = await detector.computeHash(checkerboard);
    final flatHash = await detector.computeHash(flatGrey);

    expect(detector.looksLikeDuplicate(checkerHash, flatHash), isFalse,
        reason: 'A structured checkerboard and a flat grey of the same average brightness are genuinely '
            'different images — an aHash keyed on brightness relative to a fixed 8x8 grid position should '
            'tell them apart even though a bare mean-brightness comparison would not.');
  });
}
