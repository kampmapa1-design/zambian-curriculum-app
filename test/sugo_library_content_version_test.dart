import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/services/sugo_library_content_version.dart';

/// Sugo Library Stage 1 (owner request, 2026-09-29) — guards the one
/// property the whole manifest-diff download scheme depends on: the same
/// real source always hashes the same, and any real change to it changes
/// the hash, so a client can trust "hash unchanged" to mean "content
/// unchanged" without re-downloading.
void main() {
  test('the same source parts always hash the same', () {
    final a = sugoLibraryContentVersion(['Photosynthesis', 'Explain the process']);
    final b = sugoLibraryContentVersion(['Photosynthesis', 'Explain the process']);
    expect(a, b);
  });

  test('a real change to any source part changes the hash', () {
    final a = sugoLibraryContentVersion(['Photosynthesis', 'Explain the process']);
    final b = sugoLibraryContentVersion(['Photosynthesis', 'Explain the process in detail']);
    expect(a, isNot(b));
  });

  test('blank/whitespace-only parts are ignored, not hashed as distinct content', () {
    final a = sugoLibraryContentVersion(['Photosynthesis', '']);
    final b = sugoLibraryContentVersion(['Photosynthesis']);
    expect(a, b);
  });

  test('order matters — this is the caller\'s responsibility to keep stable', () {
    final a = sugoLibraryContentVersion(['A', 'B']);
    final b = sugoLibraryContentVersion(['B', 'A']);
    expect(a, isNot(b));
  });

  test('never throws on an empty list', () {
    expect(() => sugoLibraryContentVersion(const []), returnsNormally);
  });
}
