import 'package:flutter_test/flutter_test.dart';
import 'package:zambian_curriculum_app/models/sugo_library_note.dart';
import 'package:zambian_curriculum_app/services/sugo_library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Sugo Library content (whatever is in it) is learner-format and honest', () async {
    final notes = await SugoLibraryService().bundledNotes();
    for (final entry in notes.entries) {
      final note = entry.value;
      expect(note.hasContent, isTrue, reason: entry.key);
      expect(note.sections, isNotEmpty, reason: '${entry.key}: learner format uses headed sections');
      expect(note.sourceTier, isNot(SugoLibrarySourceTier.unavailable), reason: entry.key);
      expect(note.topicName.toLowerCase(), isNot(contains('placeholder')), reason: entry.key);
      expect(note.questions.length, inInclusiveRange(2, 3), reason: entry.key);
      for (final q in note.questions) {
        expect(q.question.trim(), isNotEmpty, reason: entry.key);
        expect(q.answer.trim(), isNotEmpty, reason: entry.key);
      }
    }
  });

  test('sections and past-paper source round-trip, and practice questions carry no source', () {
    const note = SugoLibraryNote(
      topicName: 'Photosynthesis',
      sections: [SugoLibrarySection(heading: 'What it is', points: ['Plants make food using light'])],
      questions: [
        SugoLibraryQuestion(question: 'Q1', answer: 'A1', source: 'ECZ Biology Paper 2, 2017'),
        SugoLibraryQuestion(question: 'Q2', answer: 'A2'),
      ],
      sourceTier: SugoLibrarySourceTier.aiCondensed,
      contentVersion: 'abc',
    );
    final back = SugoLibraryNote.fromMap(note.toMap());
    expect(back.sections.single.heading, 'What it is');
    expect(back.sections.single.points, ['Plants make food using light']);
    expect(back.questions[0].isPastPaper, isTrue);
    expect(back.questions[0].source, 'ECZ Biology Paper 2, 2017');
    expect(back.questions[1].isPastPaper, isFalse);
    expect(back.questions[1].toMap().containsKey('s'), isFalse);
    expect(back.hasContent, isTrue);
  });
}
