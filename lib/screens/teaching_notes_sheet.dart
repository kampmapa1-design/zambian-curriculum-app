import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../services/offline_teaching_notes_service.dart';
import '../services/teaching_notes_service.dart';

/// Opens the teaching-notes generator for one scheme-of-work entry. Shows
/// notes composed offline from syllabus data immediately (free, no network),
/// with an optional AI-enhanced version behind a button that calls the
/// `generateTeachingNotes` Cloud Function — that path needs Firebase's paid
/// Blaze plan, which isn't enabled yet, so it's offered but not relied on.
Future<void> showTeachingNotesSheet(BuildContext context, {required SchemeOfWorkEntry entry}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TeachingNotesSheet(entry: entry),
  );
}

String _syllabusContext(SchemeOfWorkEntry entry) {
  final lines = <String>[
    'Topic: ${entry.topic.name}',
    if (entry.topic.description != null) entry.topic.description!,
    if (entry.subTopic != null) 'Sub-topic: ${entry.subTopic!.name}',
    if (entry.subTopic?.description != null) entry.subTopic!.description!,
    for (final o in entry.objectives) 'Learning objective: ${o.description}',
    for (final c in entry.competencies) 'Competency: ${c.description}',
  ];
  return lines.join('\n');
}

class _TeachingNotesSheet extends StatefulWidget {
  const _TeachingNotesSheet({required this.entry});

  final SchemeOfWorkEntry entry;

  @override
  State<_TeachingNotesSheet> createState() => _TeachingNotesSheetState();
}

class _TeachingNotesSheetState extends State<_TeachingNotesSheet> {
  final _offlineService = OfflineTeachingNotesService();
  final _aiService = TeachingNotesService();

  String _format = 'bullet';
  String _notes = '';
  bool _isAiGenerated = false;
  bool _loadingAi = false;
  String? _aiError;

  @override
  void initState() {
    super.initState();
    _regenerateOffline();
  }

  void _regenerateOffline() {
    setState(() {
      _notes = _offlineService.compose(entry: widget.entry, format: _format);
      _isAiGenerated = false;
      _aiError = null;
    });
  }

  Future<void> _tryAiVersion() async {
    setState(() {
      _loadingAi = true;
      _aiError = null;
    });
    try {
      final result = await _aiService.generate(
        topic: widget.entry.topic.name,
        subtopic: widget.entry.subTopic?.name,
        syllabusContext: _syllabusContext(widget.entry),
        format: _format,
      );
      if (!mounted) return;
      setState(() {
        _notes = result.notes;
        _isAiGenerated = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _aiError = 'AI-enhanced notes aren\'t available yet ($e). Showing notes from your '
          'syllabus data instead.');
    } finally {
      if (mounted) setState(() => _loadingAi = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Teaching notes', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(widget.entry.title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bullet', label: Text('Bullet points')),
                  ButtonSegment(value: 'paragraph', label: Text('Paragraphs')),
                ],
                selected: {_format},
                onSelectionChanged: _loadingAi
                    ? null
                    : (selection) {
                        setState(() => _format = selection.first);
                        if (!_isAiGenerated) _regenerateOffline();
                      },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loadingAi ? null : _tryAiVersion,
                icon: _loadingAi
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.auto_awesome),
                label: Text(_loadingAi ? 'Trying AI-enhanced version…' : 'Try AI-enhanced version (needs internet)'),
              ),
              const SizedBox(height: 12),
              if (_aiError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_aiError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Text(
                _isAiGenerated ? 'AI-generated (Claude)' : 'From your syllabus data (offline, free)',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: 6),
              Flexible(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: SelectableText(_notes),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
