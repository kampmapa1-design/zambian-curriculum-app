import 'package:flutter/material.dart';

import '../services/fine_tune_candidate_finder.dart';
import '../services/match_confidence_scorer.dart';

/// "Fine Tune" (Embedded Content Search Stage 7, 2026-09-22) — a checklist
/// of real, more specific sub-topics found bundled inside the broad topics
/// already on the generated scheme, grouped by which broad topic each one
/// sits under. Only Strong-tier candidates show by default; Moderate ones
/// sit behind a "Show more" per topic group, clearly labeled less certain
/// — nothing is ever pre-checked, the teacher opts every insertion in.
class FineTuneSuggestionsScreen extends StatefulWidget {
  const FineTuneSuggestionsScreen({super.key, required this.candidatesByTopic});

  final Map<String, List<FineTuneCandidate>> candidatesByTopic;

  @override
  State<FineTuneSuggestionsScreen> createState() => _FineTuneSuggestionsScreenState();
}

class _FineTuneSuggestionsScreenState extends State<FineTuneSuggestionsScreen> {
  final Set<String> _selectedGroupKeys = {};
  final Set<String> _expandedTopics = {};

  int get _selectedCount => _selectedGroupKeys.length;

  List<FineTuneCandidate> _selectedCandidates() => [
        for (final candidates in widget.candidatesByTopic.values)
          for (final c in candidates)
            if (_selectedGroupKeys.contains(c.groupKey)) c,
      ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fine Tune')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'We found these more specific topics that may be bundled inside a broader topic already on this '
            'scheme — insert any of these as their own scheme entries?',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          for (final topicName in widget.candidatesByTopic.keys) _topicGroup(context, topicName),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: _selectedCount == 0 ? null : () => Navigator.of(context).pop(_selectedCandidates()),
            icon: const Icon(Icons.playlist_add_check_circle_outlined),
            label: Text(_selectedCount == 0 ? 'Insert Selected' : 'Insert Selected ($_selectedCount)'),
          ),
        ),
      ),
    );
  }

  Widget _topicGroup(BuildContext context, String topicName) {
    final all = widget.candidatesByTopic[topicName]!;
    final strong = all.where((c) => c.tier == MatchConfidenceTier.strong).toList();
    final moderate = all.where((c) => c.tier == MatchConfidenceTier.moderate).toList();
    final expanded = _expandedTopics.contains(topicName);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Bundled inside "$topicName"', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final c in strong) _candidateTile(c, uncertain: false),
            if (moderate.isNotEmpty) ...[
              if (!expanded)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton(
                    onPressed: () => setState(() => _expandedTopics.add(topicName)),
                    child: Text('Show ${moderate.length} more (less certain)'),
                  ),
                )
              else
                for (final c in moderate) _candidateTile(c, uncertain: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _candidateTile(FineTuneCandidate candidate, {required bool uncertain}) {
    final selected = _selectedGroupKeys.contains(candidate.groupKey);
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => setState(() {
        if (v ?? false) {
          _selectedGroupKeys.add(candidate.groupKey);
        } else {
          _selectedGroupKeys.remove(candidate.groupKey);
        }
      }),
      title: Text(candidate.subtopicName),
      subtitle: Text(
        uncertain ? 'Less certain — ${candidate.excerpt}' : candidate.excerpt,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}
