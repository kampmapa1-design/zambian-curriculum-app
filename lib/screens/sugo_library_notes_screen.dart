import 'package:flutter/material.dart';

import '../models/sugo_library_note.dart';
import '../services/sugo_library_service.dart';
import '../theme/app_spacing.dart';

/// "Sugo Library" Stage 5-6 (owner request, 2026-09-29) — one topic's
/// bulletin notes, read entirely from the local cache once downloaded (no
/// live AI call at read time — see [SugoLibraryService]), plus its 3-5
/// recall/practice questions in simple tap-to-reveal form (self-check only,
/// no scoring).
class SugoLibraryNotesScreen extends StatefulWidget {
  const SugoLibraryNotesScreen({
    super.key,
    required this.topicId,
    this.manifestVersion,
    this.service,
  });

  final SugoLibraryTopicId topicId;
  final String? manifestVersion;
  final SugoLibraryService? service;

  @override
  State<SugoLibraryNotesScreen> createState() => _SugoLibraryNotesScreenState();
}

class _SugoLibraryNotesScreenState extends State<SugoLibraryNotesScreen> {
  late final SugoLibraryService _service = widget.service ?? SugoLibraryService();

  bool _loading = true;
  bool _refreshing = false;
  SugoLibraryNote? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final note = await _service.ensureTopic(widget.topicId.slug, manifestVersion: widget.manifestVersion);
    if (!mounted) return;
    setState(() {
      _note = note;
      _loading = false;
    });
  }

  Future<void> _forceDownload() async {
    setState(() => _refreshing = true);
    final note = await _service.downloadTopic(widget.topicId.slug);
    if (!mounted) return;
    setState(() {
      _note = note;
      _refreshing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.topicId.subTopicName == null
        ? widget.topicId.topicName
        : '${widget.topicId.topicName} — ${widget.topicId.subTopicName}';

    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_outlined),
            tooltip: 'Refresh from server',
            onPressed: _refreshing ? null : _forceDownload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _note == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      "Couldn't load this topic — you're offline and it hasn't been downloaded yet.",
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _buildContent(context, _note!),
    );
  }

  Widget _buildContent(BuildContext context, SugoLibraryNote note) {
    if (note.sourceTier == SugoLibrarySourceTier.unavailable || !note.hasContent) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Not yet available for this topic.', textAlign: TextAlign.center),
        ),
      );
    }

    Widget bullet(String line) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(right: 8), child: Text('•')),
              Expanded(child: Text(line)),
            ],
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        for (final section in note.sections) ...[
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
            child: Text(section.heading, style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final point in section.points) bullet(point),
        ],
        for (final line in note.notes) bullet(line),
        if (note.questions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('Test Yourself', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final q in note.questions) _RecallQuestionTile(question: q),
        ],
      ],
    );
  }
}

class _RecallQuestionTile extends StatefulWidget {
  const _RecallQuestionTile({required this.question});
  final SugoLibraryQuestion question;

  @override
  State<_RecallQuestionTile> createState() => _RecallQuestionTileState();
}

class _RecallQuestionTileState extends State<_RecallQuestionTile> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.question.isPastPaper ? 'Past paper — ${widget.question.source}' : 'Practice question',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: widget.question.isPastPaper
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 4),
            Text(widget.question.question, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (_revealed)
              Text(widget.question.answer, style: TextStyle(color: Theme.of(context).colorScheme.primary))
            else
              TextButton(
                onPressed: () => setState(() => _revealed = true),
                child: const Text('Tap to reveal answer'),
              ),
          ],
        ),
      ),
    );
  }
}
