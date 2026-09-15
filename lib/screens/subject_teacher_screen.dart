import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';
import 'subject_score_entry_screen.dart';

/// Stage 4 of School Network — "Subject Teacher" entry point (Data
/// Manager, per the brief). Lists every class/subject combination this
/// teacher is assigned to across their school, regardless of which
/// device the class was set up on.
class SubjectTeacherScreen extends StatefulWidget {
  const SubjectTeacherScreen({super.key});

  @override
  State<SubjectTeacherScreen> createState() => _SubjectTeacherScreenState();
}

class _Assignment {
  final SchoolClass schoolClass;
  final String subjectName;
  const _Assignment(this.schoolClass, this.subjectName);
}

class _SubjectTeacherScreenState extends State<SubjectTeacherScreen> {
  final _schoolService = SchoolService();
  final _scoreEntryService = SchoolScoreEntryService();
  bool _loading = true;
  String? _schoolId;
  List<_Assignment> _assignments = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final claim = await _schoolService.currentSchoolClaim();
    List<_Assignment> assignments = const [];
    if (uid != null && claim.schoolId != null) {
      final classes = await _scoreEntryService.myAssignedClasses(claim.schoolId!, uid);
      assignments = [
        for (final schoolClass in classes)
          for (final entry in schoolClass.subjectTeacherUids.entries)
            if (entry.value == uid) _Assignment(schoolClass, entry.key),
      ];
    }
    if (!mounted) return;
    setState(() {
      _schoolId = claim.schoolId;
      _assignments = assignments;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subject Teacher')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _schoolId == null
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text("You're not part of a school yet — join or register one from Data Manager → My School first.")),
                )
              : _assignments.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          "You're not assigned to any subjects yet. Ask your Grade Teacher to assign you from a connected class's School Network screen.",
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _assignments.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, index) {
                        final assignment = _assignments[index];
                        return ListTile(
                          leading: const Icon(Icons.edit_note_outlined),
                          title: Text(assignment.subjectName),
                          subtitle: Text(assignment.schoolClass.label),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SubjectScoreEntryScreen(
                                schoolId: _schoolId!,
                                schoolClass: assignment.schoolClass,
                                subjectName: assignment.subjectName,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
