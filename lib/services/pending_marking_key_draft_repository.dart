import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/marking_scheme.dart';
import 'marking_key_generation_service.dart';

/// Persists the ONE most-expensive, hardest-to-repeat step of the marking-
/// key upload flow — the AI's already-completed reading of the document —
/// to disk immediately once it succeeds, before the teacher even reaches
/// the subject/level/exam-type form. If Android kills the app process in
/// the background anywhere after that point (a real, normal part of the
/// Android app lifecycle under memory pressure — not preventable outright,
/// see AndroidManifest.xml's largeHeap comment), the already-done AI work
/// is not lost: the app can offer to resume right where the teacher left
/// off instead of making them re-upload and re-wait for the AI again.
///
/// Deliberately single-slot (one pending draft at a time) — matches how a
/// teacher actually uses this flow (finish or abandon one key before
/// starting the next), and keeps "is there something to resume?" a simple
/// yes/no check rather than a list to manage.
class PendingMarkingKeyDraft {
  final List<MarkingSchemeQuestion> questions;
  final List<DerivedMarkingKeySection> sections;
  final String notes;
  final String detectedTitle;
  final DateTime savedAt;

  const PendingMarkingKeyDraft({
    required this.questions,
    this.sections = const [],
    required this.notes,
    required this.detectedTitle,
    required this.savedAt,
  });

  DerivedMarkingKey get asDerivedMarkingKey =>
      DerivedMarkingKey(questions: questions, sections: sections, notes: notes, detectedTitle: detectedTitle);

  Map<String, dynamic> toJson() => {
        'questions': [
          for (final q in questions)
            {
              'label': q.label,
              'expectedAnswerOrKeywords': q.expectedAnswerOrKeywords,
              'maxMarks': q.maxMarks,
              if (q.sectionName != null) 'sectionName': q.sectionName,
            },
        ],
        'sections': [
          for (final s in sections) {'name': s.name, 'answerInstructions': s.answerInstructions},
        ],
        'notes': notes,
        'detectedTitle': detectedTitle,
        'savedAt': savedAt.toIso8601String(),
      };

  static PendingMarkingKeyDraft? fromJson(Map<String, dynamic> json) {
    final questionsRaw = json['questions'];
    if (questionsRaw is! List) return null;
    final questions = <MarkingSchemeQuestion>[];
    for (final q in questionsRaw) {
      if (q is! Map) continue;
      final label = q['label'];
      final expected = q['expectedAnswerOrKeywords'];
      final maxMarks = q['maxMarks'];
      final sectionNameRaw = q['sectionName'];
      questions.add(MarkingSchemeQuestion(
        label: label is String ? label : '',
        expectedAnswerOrKeywords: expected is String ? expected : '',
        maxMarks: maxMarks is num ? maxMarks.toDouble() : 0,
        sectionName: sectionNameRaw is String && sectionNameRaw.trim().isNotEmpty ? sectionNameRaw : null,
      ));
    }
    if (questions.isEmpty) return null;

    final sections = <DerivedMarkingKeySection>[];
    final sectionsRaw = json['sections'];
    if (sectionsRaw is List) {
      for (final s in sectionsRaw) {
        if (s is! Map) continue;
        final name = s['name'];
        if (name is! String || name.trim().isEmpty) continue;
        final instructions = s['answerInstructions'];
        sections.add(DerivedMarkingKeySection(name: name, answerInstructions: instructions is String ? instructions : ''));
      }
    }

    final savedAtRaw = json['savedAt'];
    final savedAt = savedAtRaw is String ? DateTime.tryParse(savedAtRaw) : null;
    return PendingMarkingKeyDraft(
      questions: questions,
      sections: sections,
      notes: json['notes'] is String ? json['notes'] as String : '',
      detectedTitle: json['detectedTitle'] is String ? json['detectedTitle'] as String : '',
      savedAt: savedAt ?? DateTime.now(),
    );
  }
}

class PendingMarkingKeyDraftRepository {
  static const _fileName = 'pending_marking_key_draft.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _fileName));
  }

  Future<void> save(DerivedMarkingKey derived) async {
    final draft = PendingMarkingKeyDraft(
      questions: derived.questions,
      sections: derived.sections,
      notes: derived.notes,
      detectedTitle: derived.detectedTitle,
      savedAt: DateTime.now(),
    );
    final file = await _file();
    await file.writeAsString(jsonEncode(draft.toJson()));
  }

  Future<PendingMarkingKeyDraft?> load() async {
    final file = await _file();
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return PendingMarkingKeyDraft.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
