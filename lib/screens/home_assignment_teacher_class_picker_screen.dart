import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';
import 'home_assignment_teacher_assignment_list_screen.dart';

/// Home Assignment epic, Stages 8-12 entry point — pick which of the
/// teacher's own connected classes to manage Home Assignments for.
class HomeAssignmentTeacherClassPickerScreen extends StatefulWidget {
  const HomeAssignmentTeacherClassPickerScreen({super.key});

  @override
  State<HomeAssignmentTeacherClassPickerScreen> createState() => _HomeAssignmentTeacherClassPickerScreenState();
}

class _HomeAssignmentTeacherClassPickerScreenState extends State<HomeAssignmentTeacherClassPickerScreen> {
  bool _loading = true;
  School? _school;
  List<SchoolClass> _classes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final school = await SchoolService().getCurrentSchool();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    List<SchoolClass> classes = const [];
    if (school != null && uid != null) {
      classes = await SchoolScoreEntryService().myAssignedClasses(school.id, uid);
    }
    if (!mounted) return;
    setState(() {
      _school = school;
      _classes = classes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assignment — Marking Queue')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_school == null || _classes.isEmpty)
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text("You're not assigned to any connected class yet — set that up in School Network first.")),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _classes.length,
                  itemBuilder: (context, index) {
                    final c = _classes[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.class_outlined),
                        title: Text(c.classGrade),
                        subtitle: Text(c.term),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => HomeAssignmentTeacherAssignmentListScreen(school: _school!, schoolClass: c)),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
