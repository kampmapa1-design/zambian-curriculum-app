import 'package:flutter/material.dart';

import '../services/teaching_notes_service.dart';

/// Opens the teaching-notes generator for one topic/sub-topic. Calls the
/// `generateTeachingNotes` Cloud Function — only works online, per
/// [TeachingNotesService].
Future<void> showTeachingNotesSheet(
  BuildContext context, {
  required String topic,
  String? subtopic,
  required String syllabusContext,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _TeachingNotesSheet(
      topic: topic,
      subtopic: subtopic,
      syllabusContext: syllabusContext,
    ),
  );
}

class _TeachingNotesSheet extends StatefulWidget {
  const _TeachingNotesSheet({
    required this.topic,
    this.subtopic,
    required this.syllabusContext,
  });

  final String topic;
  final String? subtopic;
  final String syllabusContext;

  @override
  State<_TeachingNotesSheet> createState() => _TeachingNotesSheetState();
}

class _TeachingNotesSheetState extends State<_TeachingNotesSheet> {
  final _service = TeachingNotesService();
  String _format = 'bullet';
  bool _loading = false;
  String? _error;
  TeachingNotesResult? _result;

  Future<void> _generate() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.generate(
        topic: widget.topic,
        subtopic: widget.subtopic,
        syllabusContext: widget.syllabusContext,
        format: _format,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
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
              Text(
                widget.subtopic == null ? widget.topic : '${widget.topic} — ${widget.subtopic}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bullet', label: Text('Bullet points')),
                  ButtonSegment(value: 'paragraph', label: Text('Paragraphs')),
                ],
                selected: {_format},
                onSelectionChanged: _loading
                    ? null
                    : (selection) => setState(() => _format = selection.first),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loading ? null : _generate,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_loading ? 'Generating…' : 'Generate teaching notes'),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (_result != null)
                Flexible(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    child: SelectableText(_result!.notes),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
