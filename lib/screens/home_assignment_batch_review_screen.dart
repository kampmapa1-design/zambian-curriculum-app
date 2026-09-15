import 'package:flutter/material.dart';

import '../models/home_assignment.dart';
import '../models/school.dart';
import '../services/home_assignment_service.dart';

/// Home Assignment epic, Stage 11 — "Before any marked batch is sent
/// back to learners, show a single review screen: score distribution for
/// the batch and any low-confidence flags. Require one 'Approve & Send
/// Batch' action — not per-script review." [MarkingConfidence] already
/// exists per graded answer (see marking_script.dart) — "low-confidence"
/// here is real AI-reported uncertainty, not an invented metric.
class HomeAssignmentBatchReviewScreen extends StatefulWidget {
  const HomeAssignmentBatchReviewScreen({required this.school, required this.schoolClass, required this.assignment, required this.submissionIds, super.key});
  final School school;
  final SchoolClass schoolClass;
  final IssuedHomeAssignment assignment;
  final List<String> submissionIds;

  @override
  State<HomeAssignmentBatchReviewScreen> createState() => _HomeAssignmentBatchReviewScreenState();
}

class _HomeAssignmentBatchReviewScreenState extends State<HomeAssignmentBatchReviewScreen> {
  final _service = HomeAssignmentService();
  bool _sending = false;
  bool _sent = false;

  Future<void> _approveAndSend() async {
    setState(() => _sending = true);
    try {
      final result = await _service.sendBatchResults(
        schoolId: widget.school.id,
        classId: widget.schoolClass.id,
        assignmentId: widget.assignment.id,
        submissionIds: widget.submissionIds,
      );
      if (!mounted) return;
      setState(() => _sent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent ${result.sent} result(s) — ${result.emailsSent} email(s), ${result.whatsappRecipients.length} WhatsApp contact(s) to tap through.')),
      );
    } on HomeAssignmentException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Batch Review')),
      body: StreamBuilder<List<HomeAssignmentSubmission>>(
        stream: _service.watchSubmissions(widget.school.id, widget.schoolClass.id, widget.assignment.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final batch = snapshot.data!.where((s) => widget.submissionIds.contains(s.id)).toList();
          if (batch.isEmpty) {
            return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('This batch is no longer available.')));
          }
          final scores = batch.where((s) => s.score != null && s.maxScore != null && s.maxScore! > 0).map((s) => s.score! / s.maxScore! * 100).toList();
          final avg = scores.isEmpty ? 0.0 : scores.reduce((a, b) => a + b) / scores.length;
          final flagged = batch.where((s) => s.hasLowConfidence).toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Score distribution', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('${batch.length} script(s) marked · average ${avg.toStringAsFixed(0)}%'),
                      const SizedBox(height: 8),
                      _distributionBar(scores),
                    ],
                  ),
                ),
              ),
              if (flagged.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  color: Colors.amber.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [Icon(Icons.flag_outlined, color: Colors.amber.shade900), const SizedBox(width: 8), Text('${flagged.length} need a closer look', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber.shade900))]),
                        const SizedBox(height: 8),
                        for (final s in flagged) Text('• ${s.learnerName} — ${s.score?.toStringAsFixed(0)}/${s.maxScore?.toStringAsFixed(0)}', style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('All results in this batch', style: Theme.of(context).textTheme.titleSmall),
              for (final s in batch)
                ListTile(
                  leading: CircleAvatar(child: Text(s.learnerName.isNotEmpty ? s.learnerName[0].toUpperCase() : '?')),
                  title: Text(s.learnerName),
                  subtitle: Text('${s.score?.toStringAsFixed(0) ?? '—'} / ${s.maxScore?.toStringAsFixed(0) ?? '—'} · ${s.markingEngine ?? ''}'),
                  trailing: s.hasLowConfidence ? const Icon(Icons.flag_outlined, color: Colors.orange) : const Icon(Icons.check_circle_outline, color: Colors.green),
                ),
              const SizedBox(height: 24),
              if (_sent)
                const Card(
                  color: Colors.green,
                  child: Padding(padding: EdgeInsets.all(16), child: Row(children: [Icon(Icons.check_circle, color: Colors.white), SizedBox(width: 12), Text('Sent', style: TextStyle(color: Colors.white))])),
                )
              else
                FilledButton.icon(
                  icon: _sending ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.send_outlined),
                  label: Text(_sending ? 'Sending...' : 'Approve & Send Batch'),
                  onPressed: _sending ? null : _approveAndSend,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _distributionBar(List<double> percentages) {
    final buckets = List<int>.filled(5, 0); // 0-20,20-40,40-60,60-80,80-100
    for (final pct in percentages) {
      final bucket = (pct / 20).floor().clamp(0, 4);
      buckets[bucket]++;
    }
    final maxCount = buckets.fold(0, (m, c) => c > m ? c : m).clamp(1, 1 << 30);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 5; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                children: [
                  Container(height: 60 * buckets[i] / maxCount, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 2),
                  Text('${i * 20}-${i * 20 + 20}', style: const TextStyle(fontSize: 9)),
                  Text('${buckets[i]}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
