import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/masonry_layout.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';
import 'broadcast_screen.dart';

/// Stage 8 of School Network (added 2026-09-13) — "a school-wide
/// dashboard visible to head_teacher, deputy, and administrator roles,
/// showing every class at the school with per-class progress: how many
/// subject teachers have completed entries vs. outstanding, by name."
/// Read-only — "full visibility" is unconditional per the brief; only
/// EDIT rights and broadcast are gated behind [School.institutionalSubscription]
/// (see `submitClassScoreEntry` in index.ts for that gating).
class LeadershipDashboardScreen extends StatelessWidget {
  const LeadershipDashboardScreen({required this.school, super.key});
  final School school;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Leadership Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.campaign_outlined),
            tooltip: 'Broadcast to Guardians',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BroadcastScreen(school: school)),
            ),
          ),
        ],
      ),
      body: ClassProgressBoard(school: school),
    );
  }
}

/// The actual "every class at the school, Grade Teacher's name alongside
/// it, per-subject completion" board — factored out of
/// [LeadershipDashboardScreen] (2026-09-14) so the web dashboard's own
/// persistent-sidebar home view (see WebDashboardHomeScreen) can use the
/// exact same live board as its default content, not a duplicate.
/// Populates itself in real time as Grade Teachers connect classes from
/// their phones (see SchoolClassLinkScreen) — nothing here needs any
/// class to have been "set up" on the web side at all.
class ClassProgressBoard extends StatelessWidget {
  const ClassProgressBoard({required this.school, super.key});
  final School school;

  @override
  Widget build(BuildContext context) {
    final scoreEntryService = SchoolScoreEntryService();
    return StreamBuilder<List<SchoolMember>>(
      stream: SchoolService().watchMembers(school.id),
      builder: (context, membersSnapshot) {
        final nameByUid = {for (final m in membersSnapshot.data ?? const <SchoolMember>[]) m.uid: m.name};
        return Column(
          children: [
            if (!school.institutionalSubscription)
              MaterialBanner(
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                content: const Text(
                  "This school doesn't have an institutional subscription yet — leadership has full visibility here but view-only access; only each class's own Grade Teacher or assigned subject teachers can edit.",
                ),
                actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
              ),
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance.collection('schools').doc(school.id).collection('classes').snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final classes = snapshot.data!.docs.map((d) => SchoolClass.fromMap(d.id, d.data())).toList();
                  if (classes.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          'No classes connected to School Network yet — a class appears here as soon as its Grade '
                          'Teacher connects it from the phone app (Broad Mark Sheet → School Network → Connect).',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return _ClassProgressGrid(
                    school: school,
                    classes: classes,
                    scoreEntryService: scoreEntryService,
                    nameByUid: nameByUid,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Bento-grid masonry (Stage K, 2026-09-27): each class's progress card is
/// a genuinely different height (it grows with how many subjects that
/// class has — real varying content, not an artificial size difference),
/// and this board runs on a web dashboard where a single column wastes
/// most of a wide browser window's width. A single-column phone/narrow
/// browser view is completely unchanged (see [masonryColumnCountFor]) —
/// only wide viewports switch to a multi-column, height-balanced layout.
class _ClassProgressGrid extends StatelessWidget {
  const _ClassProgressGrid({required this.school, required this.classes, required this.scoreEntryService, required this.nameByUid});

  final School school;
  final List<SchoolClass> classes;
  final SchoolScoreEntryService scoreEntryService;
  final Map<String, String> nameByUid;

  Widget _cardFor(int index) =>
      _ClassProgressCard(school: school, schoolClass: classes[index], scoreEntryService: scoreEntryService, nameByUid: nameByUid);

  /// A class with more subjects renders a taller card (one row per
  /// subject, see `_ClassProgressCard._subjectProgressRow`) — a cheap,
  /// real proxy for actual pixel height, good enough to balance columns
  /// without needing to measure real widgets.
  double _estimatedHeight(int index) => 90 + classes[index].subjectNames.length * 22;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = masonryColumnCountFor(constraints.maxWidth);
        if (columnCount == 1) {
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: classes.length,
            itemBuilder: (context, index) => _cardFor(index),
          );
        }

        final columns = assignMasonryColumns(itemCount: classes.length, columnCount: columnCount, estimatedHeight: _estimatedHeight);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columnCount; c++) ...[
                if (c > 0) const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [for (final index in columns[c]) _cardFor(index)],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ClassProgressCard extends StatelessWidget {
  const _ClassProgressCard({required this.school, required this.schoolClass, required this.scoreEntryService, required this.nameByUid});
  final School school;
  final SchoolClass schoolClass;
  final SchoolScoreEntryService scoreEntryService;
  final Map<String, String> nameByUid;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(schoolClass.label, style: Theme.of(context).textTheme.titleMedium),
            Text('Grade Teacher: ${schoolClass.gradeTeacherName}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            StreamBuilder<List<ScoreEntry>>(
              stream: scoreEntryService.watchEntries(school.id, schoolClass.id),
              builder: (context, snapshot) {
                final entries = snapshot.data ?? const [];
                final totalLearners = schoolClass.learnerNames.length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final subject in schoolClass.subjectNames)
                      _subjectProgressRow(context, subject, entries, totalLearners, nameByUid),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _subjectProgressRow(BuildContext context, String subject, List<ScoreEntry> entries, int totalLearners, Map<String, String> nameByUid) {
    final teacherUid = schoolClass.subjectTeacherUids[subject];
    final teacherName = teacherUid == null ? 'Unassigned' : (nameByUid[teacherUid] ?? teacherUid);
    final completed = entries.where((e) => e.subjectName == subject).length;
    final isComplete = totalLearners > 0 && completed >= totalLearners;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(subject, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Text(
              teacherName,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Text(
            isComplete ? 'Complete ($completed/$totalLearners)' : 'Outstanding ($completed/$totalLearners)',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isComplete ? Colors.green : Colors.amber.shade800,
            ),
          ),
        ],
      ),
    );
  }
}
