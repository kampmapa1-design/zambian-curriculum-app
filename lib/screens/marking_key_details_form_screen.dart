import 'package:flutter/material.dart';

/// What a teacher types in for a newly-derived marking key/scheme, once
/// the AI has actually read the document — replaces the old subject/
/// grade/topic PICKER (constrained to the app's bundled syllabus data,
/// one topic at a time) for this flow specifically. A full mock exam or
/// past paper doesn't map to a single bundled topic, so these are plain
/// manual text fields the teacher fills in themselves, not a dropdown.
class MarkingKeyDetails {
  final String subjectName;
  final String level;
  final String examType;

  const MarkingKeyDetails({required this.subjectName, required this.level, required this.examType});
}

/// The manual-entry form shown right after a marking key is read: Subject
/// Name, Level (e.g. Secondary/High School, Tertiary), and Type of Exam
/// (e.g. "Final secondary school exit exam", "University semester exam")
/// — three plain text fields, no picker. If the AI detected a title/
/// heading on the document itself, a gentle mismatch warning appears
/// when what the teacher typed for "type of exam" shares little in
/// common with it — a nudge to double-check, never a hard block.
class MarkingKeyDetailsFormScreen extends StatefulWidget {
  const MarkingKeyDetailsFormScreen({super.key, this.detectedTitle, this.questionCount});

  final String? detectedTitle;
  final int? questionCount;

  @override
  State<MarkingKeyDetailsFormScreen> createState() => _MarkingKeyDetailsFormScreenState();
}

class _MarkingKeyDetailsFormScreenState extends State<MarkingKeyDetailsFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _subjectController = TextEditingController();
  final _levelController = TextEditingController();
  final _examTypeController = TextEditingController();

  @override
  void dispose() {
    _subjectController.dispose();
    _levelController.dispose();
    _examTypeController.dispose();
    super.dispose();
  }

  /// Simple, honest word-overlap check — not a claim of real semantic
  /// understanding, just "do these two short phrases share any
  /// significant word at all", to catch an obvious mismatch (wrong
  /// subject typed, wrong exam entirely) without being a strict or
  /// fragile exact-match requirement.
  bool _looksLikeMismatch(String typed, String detected) {
    if (detected.trim().isEmpty) return false;
    const stopWords = {'the', 'a', 'an', 'of', 'for', 'and', 'exam', 'exit'};
    Set<String> words(String s) =>
        s.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 2 && !stopWords.contains(w)).toSet();
    final typedWords = words(typed);
    final detectedWords = words(detected);
    if (typedWords.isEmpty || detectedWords.isEmpty) return false;
    return typedWords.intersection(detectedWords).isEmpty;
  }

  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final combined = '${_subjectController.text} ${_examTypeController.text}';
    final detected = widget.detectedTitle ?? '';
    if (_looksLikeMismatch(combined, detected)) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Double-check this'),
          content: Text(
            'The document itself appears to say:\n\n"$detected"\n\n'
            'That doesn\'t obviously match what you entered ("${_subjectController.text.trim()} — '
            '${_examTypeController.text.trim()}"). Is this the right marking key?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Let me check again')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes, continue')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(MarkingKeyDetails(
      subjectName: _subjectController.text.trim(),
      level: _levelController.text.trim(),
      examType: _examTypeController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subject & Level')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              if (widget.questionCount case final n?)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'Found $n question(s). Fill in a few details to file this marking key correctly.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              TextFormField(
                controller: _subjectController,
                decoration: const InputDecoration(labelText: 'Subject name', border: OutlineInputBorder()),
                textCapitalization: TextCapitalization.words,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the subject name' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _levelController,
                decoration: const InputDecoration(
                  labelText: 'Level (e.g. Secondary/High School, Tertiary)',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the level' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _examTypeController,
                decoration: const InputDecoration(
                  labelText: 'Type of exam (e.g. Final secondary exit exam, University semester exam)',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the type of exam' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _continue, child: const Text('Continue')),
            ],
          ),
        ),
      ),
    );
  }
}
