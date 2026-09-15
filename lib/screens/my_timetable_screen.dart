import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../models/timetable.dart';
import '../services/timetable_service.dart';

const _kWeekdayLabels = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Timetable Generation, Stage 8 — "platform capability split." Full
/// setup, generation, and editing stays web-only (see
/// GeneratedTimetableScreen and its siblings, reachable only from the web
/// dashboard sidebar); mobile's own place in this feature is a read-only
/// view of a teacher's OWN periods — genuinely useful ("what am I
/// teaching today") without needing anything mobile-specific to write.
class MyTimetableScreen extends StatelessWidget {
  const MyTimetableScreen({required this.school, super.key});
  final School school;

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('My Timetable')),
      body: myUid == null
          ? const Center(child: Text('Sign in to see your timetable.'))
          : StreamBuilder<GeneratedTimetable?>(
              stream: TimetableService().watchGenerated(school.id),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                final generated = snapshot.data;
                final mine = (generated?.assignments ?? const <TimetableAssignment>[]).where((a) => a.teacherUid == myUid).toList()
                  ..sort((a, b) => a.day != b.day ? a.day.compareTo(b.day) : a.period.compareTo(b.period));
                if (mine.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('No timetable periods are assigned to you yet.')),
                  );
                }
                final byDay = <int, List<TimetableAssignment>>{};
                for (final a in mine) {
                  (byDay[a.day] ??= []).add(a);
                }
                final days = byDay.keys.toList()..sort();
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final day in days) ...[
                      Text(_kWeekdayLabels[day.clamp(0, 6)], style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      for (final a in byDay[day]!)
                        Card(
                          child: ListTile(
                            leading: CircleAvatar(child: Text('${a.period + 1}')),
                            title: Text(a.subjectName),
                            subtitle: Text(a.className),
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],
                  ],
                );
              },
            ),
    );
  }
}
