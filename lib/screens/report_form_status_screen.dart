import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';

/// "Report Form Status" (added 2026-09-14, per direct follow-up request)
/// — per-class progression percentage, plus whether each class's mid-term
/// scores were entered within the Head Teacher/Deputy's configured
/// Mid-Term Results Window (Stage 5, minimal version — see
/// `setMidTermWindow` in index.ts). Populates live from the same
/// `scoreEntries` data [ClassProgressBoard] already reads — this is a
/// different LENS on the same underlying data (deadline compliance +
/// overall %), not a separate tracking system.
class ReportFormStatusScreen extends StatefulWidget {
  const ReportFormStatusScreen({required this.school, required this.canEditWindow, super.key});
  final School school;
  final bool canEditWindow;

  @override
  State<ReportFormStatusScreen> createState() => _ReportFormStatusScreenState();
}

class _ReportFormStatusScreenState extends State<ReportFormStatusScreen> {
  final _schoolService = SchoolService();
  bool _saving = false;

  Future<void> _pickWindowStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.school.midTermWindowStart ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() => _saving = true);
    try {
      await _schoolService.setMidTermWindow(schoolId: widget.school.id, startDate: picked);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mid-Term Results Window updated.')));
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final school = widget.school;
    final windowStart = school.midTermWindowStart;
    final windowEnd = school.midTermWindowEnd;
    final now = DateTime.now();
    final windowIsOpen = windowStart != null && windowEnd != null && now.isAfter(windowStart) && now.isBefore(windowEnd);

    return Scaffold(
      appBar: AppBar(title: const Text('Report Form Status')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Mid-Term Results Window', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (windowStart == null) ...[
                    const Text("Not set yet — classes' mid-term entries can't be checked against a deadline until this is set."),
                    if (widget.canEditWindow) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        icon: const Icon(Icons.date_range_outlined),
                        label: Text(_saving ? 'Saving...' : 'Set start date (2-week window)'),
                        onPressed: _saving ? null : _pickWindowStart,
                      ),
                    ] else
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('Ask your Head Teacher or Deputy to set this.', style: TextStyle(fontSize: 12)),
                      ),
                  ] else ...[
                    Text('${_formatDate(windowStart)} – ${_formatDate(windowEnd!)}'),
                    const SizedBox(height: 4),
                    Text(
                      windowIsOpen ? 'Open now' : (now.isBefore(windowStart) ? 'Not started yet' : 'Closed'),
                      style: TextStyle(
                        color: windowIsOpen ? Colors.green : Colors.grey,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.canEditWindow) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.edit_calendar_outlined),
                        label: Text(_saving ? 'Saving...' : 'Change start date'),
                        onPressed: _saving ? null : _pickWindowStart,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('By class', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('schools').doc(school.id).collection('classes').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final classes = snapshot.data!.docs.map((d) => SchoolClass.fromMap(d.id, d.data())).toList();
              if (classes.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No classes connected to School Network yet.'),
                );
              }
              return Column(
                children: [for (final c in classes) _ClassStatusCard(school: school, schoolClass: c, windowStart: windowStart, windowEnd: windowEnd)],
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) => '${d.day}/${d.month}/${d.year}';
}

class _ClassStatusCard extends StatelessWidget {
  const _ClassStatusCard({required this.school, required this.schoolClass, required this.windowStart, required this.windowEnd});
  final School school;
  final SchoolClass schoolClass;
  final DateTime? windowStart;
  final DateTime? windowEnd;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: StreamBuilder<List<ScoreEntry>>(
          stream: SchoolScoreEntryService().watchEntries(school.id, schoolClass.id),
          builder: (context, snapshot) {
            final entries = snapshot.data ?? const [];
            final totalPossible = schoolClass.learnerNames.length * schoolClass.subjectNames.length;
            final percent = totalPossible == 0 ? 0.0 : (entries.length / totalPossible * 100).clamp(0, 100);

            int? onTime;
            int? late;
            if (windowStart != null && windowEnd != null) {
              onTime = entries.where((e) => e.submittedAt != null && !e.submittedAt!.isBefore(windowStart!) && !e.submittedAt!.isAfter(windowEnd!)).length;
              late = entries.where((e) => e.submittedAt != null && e.submittedAt!.isAfter(windowEnd!)).length;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(schoolClass.label, style: Theme.of(context).textTheme.titleSmall),
                Text('Grade Teacher: ${schoolClass.gradeTeacherName}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: percent / 100, minHeight: 8),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('${percent.toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Report form processing: ${percent.toStringAsFixed(0)}% overall (${entries.length}/$totalPossible entries)',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (onTime != null && late != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.check_circle_outline, size: 14, color: Colors.green.shade600),
                      const SizedBox(width: 4),
                      Text('$onTime entered within window', style: TextStyle(fontSize: 11, color: Colors.green.shade700)),
                      const SizedBox(width: 12),
                      if (late > 0) ...[
                        Icon(Icons.warning_amber_outlined, size: 14, color: Colors.amber.shade800),
                        const SizedBox(width: 4),
                        Text('$late entered late', style: TextStyle(fontSize: 11, color: Colors.amber.shade800)),
                      ],
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
