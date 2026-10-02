import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/sugo_library_note.dart';
import 'package:zambian_curriculum_app/services/sugo_library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Sugo Library content parses and is honest about its tiers', () async {
    final notes = await SugoLibraryService().bundledNotes();
    expect(notes, isNotEmpty);
    for (final entry in notes.entries) {
      final note = entry.value;
      expect(note.notes, isNotEmpty, reason: entry.key);
      expect(note.sourceTier, isNot(SugoLibrarySourceTier.unavailable), reason: entry.key);
      expect(note.topicName.toLowerCase(), isNot(contains('placeholder')), reason: entry.key);
      if (note.sourceTier == SugoLibrarySourceTier.aiCondensed) {
        expect(note.questions.length, inInclusiveRange(3, 5), reason: entry.key);
      } else {
        expect(note.questions, isEmpty, reason: entry.key);
      }
    }
  });
}
