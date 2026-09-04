import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../services/topic_search_service.dart';
import 'generate_notes_by_topic_screen.dart';
import 'term_topic_picker_screen.dart';
import 'topic_picker_flow.dart';

/// Topic search, Method 2 — the front door for features that need a
/// specific topic (added 2026-09-02). A free-text box first ("tell me
/// what you're teaching"), with "Browse by Grade/Term/Week instead"
/// always available as a fallback to Method 1's plain drill-down — this
/// never replaces that, only sits in front of it. See
/// topic_search_service.dart for the two-tier search itself (local word
/// match, then an AI-assisted fallback that only ever narrows to a real
/// subject/grade, never invents a topic).
class TopicSearchScreen extends StatefulWidget {
  const TopicSearchScreen({super.key, required this.title, this.searchService});

  final String title;
  final TopicSearchService? searchService;

  @override
  State<TopicSearchScreen> createState() => _TopicSearchScreenState();
}

class _TopicSearchScreenState extends State<TopicSearchScreen> {
  late final TopicSearchService _searchService = widget.searchService ?? TopicSearchService();
  final _queryController = TextEditingController();

  bool _searching = false;
  bool _searchedOnce = false;
  List<TopicSearchResult> _results = [];
  String? _error;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _searchedOnce = true;
      _error = null;
    });
    try {
      final results = await _searchService.searchLocal(query);
      if (!mounted) return;
      setState(() => _results = results);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _askAi() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final template = await _searchService.searchWithAiAssist(query);
      if (!mounted) return;
      if (template == null) {
        setState(() => _error = "AI couldn't find a clear match either. Try different wording, or browse instead.");
        return;
      }
      final entry = await Navigator.of(context).push<SchemeOfWorkEntry>(
        MaterialPageRoute(builder: (_) => TermTopicPickerScreen(template: template)),
      );
      if (entry == null || !mounted) return;
      Navigator.of(context).pop(TopicPickResult(template: template, entry: entry));
    } on TopicSearchUnavailable catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _browseInstead() async {
    final result = await pickTopicViaTermWeek(context, title: widget.title);
    if (result == null || !mounted) return;
    Navigator.of(context).pop(result);
  }

  /// A topic typed directly, not tied to the bundled syllabus at all — see
  /// GenerateNotesByTopicScreen's own doc comment. Doesn't pop this screen
  /// on return: unlike Search/Browse, that screen handles its own output
  /// (sharing a document/deck) entirely by itself, so there's nothing for
  /// the caller of THIS screen to receive.
  Future<void> _openGenerateByTopic() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GenerateNotesByTopicScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('What are you teaching? (e.g. "Grade 10 Biology, plant reproduction")'),
          const SizedBox(height: 8),
          TextField(
            controller: _queryController,
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Search…'),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _searching ? null : _browseInstead,
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('Browse Instead'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _searching ? null : _openGenerateByTopic,
            icon: const Icon(Icons.auto_stories_outlined),
            label: const Text('Generate Notes & Slides by Topic'),
          ),
          const SizedBox(height: 16),
          if (_searching) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
          if (_error != null) Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          if (!_searching && _searchedOnce && _results.isEmpty) ...[
            const Text("Nothing on-device shares that wording. Ask AI to help, or browse by Grade/Term/Week instead."),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _searching ? null : _askAi,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Ask AI to Help Find This'),
            ),
          ],
          for (final result in _results)
            Card(
              child: ListTile(
                title: Text(result.entry.title),
                subtitle: Text(
                  '${result.template.subject.name} · ${result.template.grade.name} · ${result.term.name}'
                  '${result.entry.realWeekNumber != null ? ' · Week ${result.entry.realWeekNumber}' : ''}',
                ),
                onTap: () => Navigator.of(context).pop(TopicPickResult(template: result.template, entry: result.entry)),
              ),
            ),
        ],
      ),
    );
  }
}
