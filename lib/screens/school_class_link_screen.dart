import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/report_class.dart';
import '../models/school.dart';
import '../services/pupil_class_link_service.dart';
import '../services/report_class_repository.dart';
import '../services/school_class_link_service.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';
import 'timetable_entry_from_photo_screen.dart';

/// School Network, Milestone B1 — "Connect to School Network" for one
/// class, plus (once connected) assigning a subject teacher to each of
/// its subjects. Reached from BroadMarkSheetScreen's app bar.
class SchoolClassLinkScreen extends StatefulWidget {
  const SchoolClassLinkScreen({
    required this.reportClass,
    required this.learners,
    required this.subjects,
    super.key,
  });

  final ReportClass reportClass;
  // Full local rows (not just names) — needed to map a subject teacher's
  // decentralized score entries back onto the right local learner/subject
  // row when syncing (see _syncScores).
  final List<ReportLearner> learners;
  final List<ReportSubject> subjects;

  @override
  State<SchoolClassLinkScreen> createState() => _SchoolClassLinkScreenState();
}

class _SchoolClassLinkScreenState extends State<SchoolClassLinkScreen> {
  final _schoolService = SchoolService();
  final _linkService = SchoolClassLinkService();
  final _scoreEntryService = SchoolScoreEntryService();
  final _reportClassRepository = ReportClassRepository();
  final _pupilLinkService = PupilClassLinkService();
  bool _syncing = false;

  bool _loading = true;
  School? _school;
  SchoolClass? _schoolClass;
  List<SchoolMember> _members = const [];
  bool _connecting = false;
  String? _error;
  bool _shareGuardianContacts = true;
  bool _isLeadership = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final school = await _schoolService.getCurrentSchool();
    SchoolClass? schoolClass;
    List<SchoolMember> members = const [];
    if (school != null && widget.reportClass.firestoreClassId != null) {
      schoolClass = await _linkService.getClass(school.id, widget.reportClass.firestoreClassId!);
      members = await _schoolService.watchMembers(school.id).first;
    }
    final claim = await _schoolService.currentSchoolClaim();
    final isLeadership = claim.role?.isLeadership == true || claim.role == SchoolRole.administrator;
    if (!mounted) return;
    setState(() {
      _school = school;
      _schoolClass = schoolClass;
      _members = members;
      _isLeadership = isLeadership;
      _loading = false;
    });
  }

  Future<void> _connect() async {
    final school = _school;
    if (school == null) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final schoolClass = await _linkService.connectClass(
        schoolId: school.id,
        reportClass: widget.reportClass,
        learnerNames: widget.learners.map((l) => l.fullName).toList(),
        subjectNames: widget.subjects.map((s) => s.name).toList(),
        guardianContacts: _shareGuardianContacts
            ? [for (final l in widget.learners) (email: l.guardianEmail, phone: l.guardianPhone)]
            : null,
      );
      final members = await _schoolService.watchMembers(school.id).first;
      if (!mounted) return;
      setState(() {
        _schoolClass = schoolClass;
        _members = members;
      });
    } on SchoolException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _respondToPupilLink(SchoolClass schoolClass, PupilClassLinkRequest req, bool approve) async {
    try {
      await _pupilLinkService.respondToLink(schoolId: _school!.id, classId: schoolClass.id, pupilUid: req.pupilUid, approve: approve);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(approve ? '${req.learnerName} linked.' : 'Request declined.')));
    } on PupilClassLinkException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // Real uids never equal this — used to distinguish "picked Unassigned"
  // from "dismissed the dialog without picking anything" (showDialog
  // returns null for both otherwise, and dismissing must never
  // accidentally unassign a subject).
  static const _unassignedSentinel = '__unassigned__';

  Future<void> _assignSubject(String subjectName) async {
    final school = _school;
    final schoolClass = _schoolClass;
    if (school == null || schoolClass == null) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Assign $subjectName to'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_unassignedSentinel),
            child: const Text('— Unassigned —'),
          ),
          for (final member in _members)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(member.uid),
              child: Text(member.name.isEmpty ? member.uid : member.name),
            ),
        ],
      ),
    );
    if (picked == null) return; // dismissed — no change
    final targetUid = picked == _unassignedSentinel ? null : picked;
    try {
      await _linkService.assignSubjectTeacher(
        schoolId: school.id,
        classId: schoolClass.id,
        subjectName: subjectName,
        targetUid: targetUid,
      );
      final refreshed = await _linkService.getClass(school.id, schoolClass.id);
      if (!mounted) return;
      setState(() => _schoolClass = refreshed);
    } on SchoolException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('School Network')),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_school == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text("You're not part of a school yet — join or register one from Data Manager → My School first.")),
      );
    }
    final schoolClass = _schoolClass;
    if (schoolClass == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Connect "${widget.reportClass.classGrade} (${widget.reportClass.term})" to ${_school!.name} '
              'so subject teachers can update their own scores directly from their own devices.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              value: _shareGuardianContacts,
              onChanged: (value) => setState(() => _shareGuardianContacts = value),
              title: const Text('Also share guardian contacts'),
              subtitle: const Text(
                "Lets school leadership send broadcast messages to parents/guardians (only visible to Head Teacher, Deputy, and Administrator — not other teachers). Off means only names/scores are shared, no contact info.",
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _connecting ? null : _connect,
              child: _connecting
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Text('Connect to School Network'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(schoolClass.label, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('${schoolClass.learnerNames.length} learners · Connected to ${_school!.name}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Subject teachers', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Assign who can update each subject\'s scores directly from their own device.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        for (final subject in schoolClass.subjectNames)
          ListTile(
            title: Text(subject),
            subtitle: Text(_memberName(schoolClass.subjectTeacherUids[subject]) ?? 'Unassigned'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _assignSubject(subject),
          ),
        if (_isLeadership) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Set Up Timetable from Photo'),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TimetableEntryFromPhotoScreen(school: _school!, schoolClass: schoolClass, members: _members),
                ),
              );
              if (mounted) _load();
            },
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              "Photograph this class's paper timetable — reads periods/day, teaching days, and each subject's "
              'teacher, all shown for you to review before anything is saved.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
        if (_isLeadership || schoolClass.gradeTeacherUid == FirebaseAuth.instance.currentUser?.uid) ...[
          const SizedBox(height: 16),
          Text('Pupil join requests', style: Theme.of(context).textTheme.titleSmall),
          StreamBuilder<List<PupilClassLinkRequest>>(
            stream: _pupilLinkService.watchPendingLinks(_school!.id, schoolClass.id),
            builder: (context, snapshot) {
              final requests = snapshot.data ?? const [];
              if (requests.isEmpty) {
                return const Padding(padding: EdgeInsets.only(top: 4), child: Text('No pending requests.', style: TextStyle(fontSize: 12, color: Colors.grey)));
              }
              return Column(
                children: [
                  for (final req in requests)
                    Card(
                      child: ListTile(
                        title: Text(req.learnerName),
                        subtitle: const Text('Wants to join as this pupil'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(icon: const Icon(Icons.check, color: Colors.green), onPressed: () => _respondToPupilLink(schoolClass, req, true)),
                            IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: () => _respondToPupilLink(schoolClass, req, false)),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: _syncing
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4))
              : const Icon(Icons.sync),
          label: const Text('Sync scores from subject teachers'),
          onPressed: _syncing ? null : _syncScores,
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Pulls in what subject teachers have entered on their own devices. Continuous Assessment subjects still need Test/Exam entered manually here.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Pulls subject teachers' decentralized [ScoreEntry] rows (Milestone
  /// B2) into this device's own local report_scores, via the SAME
  /// `setScore` every other entry point in this pipeline already uses —
  /// so post-completion red-flagging, etc. all keep working unchanged.
  /// Continuous-Assessment subjects are deliberately skipped: a
  /// decentralized entry doesn't say whether it's the Test or Exam
  /// component, and guessing would be worse than asking the Grade
  /// Teacher to enter those two manually — a real, disclosed limitation,
  /// not a bug.
  Future<void> _syncScores() async {
    final schoolClass = _schoolClass;
    if (schoolClass == null) return;
    setState(() => _syncing = true);
    try {
      final entries = await _scoreEntryService.watchEntries(_school!.id, schoolClass.id).first;
      var synced = 0;
      var skippedCa = 0;
      var skippedNoMatch = 0;
      for (final entry in entries) {
        if (entry.learnerIndex < 0 || entry.learnerIndex >= widget.learners.length) {
          skippedNoMatch++;
          continue;
        }
        final learner = widget.learners[entry.learnerIndex];
        ReportSubject? subject;
        for (final s in widget.subjects) {
          if (s.name == entry.subjectName) {
            subject = s;
            break;
          }
        }
        if (subject == null || subject.isComposite) {
          skippedNoMatch++;
          continue;
        }
        if (widget.reportClass.isContinuousAssessment) {
          skippedCa++;
          continue;
        }
        await _reportClassRepository.setScore(
          learnerId: learner.id,
          subject: subject,
          score: entry.score,
          comment: entry.comment.isEmpty ? null : entry.comment,
          commentSource: entry.comment.isEmpty ? null : ReportCommentSource.manual,
        );
        synced++;
      }
      if (!mounted) return;
      final parts = <String>['Synced $synced score${synced == 1 ? '' : 's'}.'];
      if (skippedCa > 0) parts.add('$skippedCa need manual entry (Continuous Assessment).');
      if (skippedNoMatch > 0) parts.add("$skippedNoMatch didn't match a current learner/subject.");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(parts.join(' '))));
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String? _memberName(String? uid) {
    if (uid == null) return null;
    for (final member in _members) {
      if (member.uid == uid) return member.name;
    }
    return uid;
  }
}
