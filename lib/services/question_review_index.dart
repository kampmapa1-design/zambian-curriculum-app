import '../models/concise_marking_record.dart';
import '../models/marking_scheme.dart';
import '../models/marking_script.dart';

/// Where the Stage 6 review screen's LEFT pane should look for "what the
/// question actually asked / expected" — the best source available for a
/// given question, never invented.
enum QuestionKeySourceKind {
  /// A photographed question-paper page was attached. There is no
  /// bounding-box location for a question ON it (the AI is never asked to
  /// find one — see [QuestionReviewIndex]'s own doc comment), so this is a
  /// page a teacher flips to, not an auto-highlighted spot.
  questionPaperImage,

  /// The script was marked against a keyed [MarkingScheme] — that
  /// question's own expected-answer/keywords text.
  schemeText,

  /// Neither exists for this question (pure-AI marking, no question paper
  /// attached) — the review screen shows the right (script) pane alone.
  none,
}

class QuestionKeySource {
  final QuestionKeySourceKind kind;

  /// Which question-paper image to show, for [QuestionKeySourceKind.questionPaperImage]
  /// — null when more than one was attached and which one holds this
  /// question isn't known (the teacher flips through manually).
  final int? imageIndex;

  /// The scheme's own text, for [QuestionKeySourceKind.schemeText].
  final String? expectedAnswerText;

  const QuestionKeySource.questionPaper(this.imageIndex)
      : kind = QuestionKeySourceKind.questionPaperImage,
        expectedAnswerText = null;
  const QuestionKeySource.schemeText(this.expectedAnswerText)
      : kind = QuestionKeySourceKind.schemeText,
        imageIndex = null;
  const QuestionKeySource.none()
      : kind = QuestionKeySourceKind.none,
        imageIndex = null,
        expectedAnswerText = null;
}

/// Everything the Stage 6 review screen needs for ONE question: its mark/
/// comment, where it sits on the real marked script, and the best available
/// source for the question itself.
class QuestionReviewEntry {
  final String questionLabel;
  final GradedAnswer? answer;

  /// The student's answer's location on the photographed script, from the
  /// SAME bounding-box data gradeMarkingScriptConcise already produces for
  /// the on-image tick/cross. Null (or [ScriptAnnotationRecord.hasLocation]
  /// false) when the AI wasn't confident enough to place it — same "never
  /// guess a location" rule as everywhere else this data is used.
  final ScriptAnnotationRecord? scriptLocation;

  final QuestionKeySource keySource;

  const QuestionReviewEntry({
    required this.questionLabel,
    this.answer,
    this.scriptLocation,
    required this.keySource,
  });

  bool get hasScriptLocation => scriptLocation?.hasLocation == true;
}

/// Marking Reliability Stage 5 (2026-09-22, per explicit request): maps
/// each question on a marked script to its mark, its location on the real
/// photographed script, and the best available source for what the
/// question actually asked — drives the Stage 6 side-by-side review screen
/// (tapping a question number scrolls/centres both panes on it at once).
///
/// Built from data that already exists once a script is marked —
/// [MarkingScript.gradedAnswers] and [ConciseMarkingRecord.annotations] —
/// so it works identically for a script just marked in the live session and
/// for one reopened later from the marked-scripts list; no new AI call.
///
/// HONEST LIMITATION, by design: there is no bounding box for WHERE a
/// question sits on a photographed QUESTION-PAPER page — the AI is never
/// asked to locate one there (only on the student's own script), and
/// inventing a location would be exactly the kind of guess this app's other
/// AI features are built to avoid. When a question paper was attached, its
/// page is offered as something to flip to, not an auto-highlighted spot —
/// see [QuestionKeySourceKind.questionPaperImage].
class QuestionReviewIndex {
  final List<String> orderedLabels;
  final Map<String, QuestionReviewEntry> byLabel;

  const QuestionReviewIndex({required this.orderedLabels, required this.byLabel});

  static const empty = QuestionReviewIndex(orderedLabels: [], byLabel: {});

  bool get isEmpty => orderedLabels.isEmpty;
  int get length => orderedLabels.length;
  QuestionReviewEntry? operator [](String label) => byLabel[label];
  QuestionReviewEntry? entryAt(int i) => (i >= 0 && i < orderedLabels.length) ? byLabel[orderedLabels[i]] : null;
  int indexOfLabel(String label) => orderedLabels.indexOf(label);

  factory QuestionReviewIndex.build({
    required List<GradedAnswer> answers,
    List<ScriptAnnotationRecord> annotations = const [],
    MarkingScheme? scheme,
    int questionPaperImageCount = 0,
  }) {
    final annotationByLabel = {for (final a in annotations) a.questionLabel: a};
    final schemeByLabel = {for (final q in scheme?.questions ?? const <MarkingSchemeQuestion>[]) q.label: q};
    // A single question-paper image is by far the common case for these
    // papers, so every question defaults to it — the pane has something to
    // show without the teacher hunting for it. More than one page is left
    // for the teacher to flip through (see class doc: no per-question
    // location exists on a question-paper page either way).
    final singlePaperImageIndex = questionPaperImageCount == 1 ? 0 : null;

    final labels = <String>[];
    final byLabel = <String, QuestionReviewEntry>{};
    for (final a in answers) {
      if (byLabel.containsKey(a.questionLabel)) continue; // defensive: never index one label twice
      labels.add(a.questionLabel);

      final schemeQuestion = schemeByLabel[a.questionLabel];
      final QuestionKeySource keySource;
      if (schemeQuestion != null && schemeQuestion.expectedAnswerOrKeywords.trim().isNotEmpty) {
        keySource = QuestionKeySource.schemeText(schemeQuestion.expectedAnswerOrKeywords);
      } else if (singlePaperImageIndex != null) {
        keySource = QuestionKeySource.questionPaper(singlePaperImageIndex);
      } else if (questionPaperImageCount > 1) {
        keySource = const QuestionKeySource.questionPaper(null);
      } else {
        keySource = const QuestionKeySource.none();
      }

      byLabel[a.questionLabel] = QuestionReviewEntry(
        questionLabel: a.questionLabel,
        answer: a,
        scriptLocation: annotationByLabel[a.questionLabel],
        keySource: keySource,
      );
    }
    return QuestionReviewIndex(orderedLabels: labels, byLabel: byLabel);
  }
}
