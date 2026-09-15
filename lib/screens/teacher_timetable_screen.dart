import 'package:flutter/material.dart';

import '../models/school.dart';
import '../models/timetable.dart';
import '../services/school_service.dart';
import '../services/staffroom_service.dart';
import '../services/timetable_export_service.dart';
import '../services/timetable_service.dart';
import '../services/timetable_share_service.dart';
import 'timetable_grid_widget.dart';

/// Timetable Generation, Stage 11 — "By Teacher" view for ONE teacher:
/// their complete personal schedule across every class/subject they
/// teach, in the same grid format as the class view (see
/// [TimetableGrid]) — just with each cell showing the CLASS instead of
/// the teacher (there's only one teacher here, so naming them again in
/// every cell would be redundant). Read-only and available on both
/// mobile and web — no PC-only restriction, per the brief, since
/// nothing here writes anything.
class TeacherTimetableScreen extends StatefulWidget {
  const TeacherTimetableScreen({required this.school, required this.teacherUid, required this.teacherName, super.key});
  final School school;
  final String teacherUid;
  final String teacherName;

  @override
  State<TeacherTimetableScreen> createState() => _TeacherTimetableScreenState();
}

class _TeacherTimetableScreenState extends State<TeacherTimetableScreen> {
  final _timetableService = TimetableService();
  final _schoolService = SchoolService();
  final _exportService = TimetableExportService();
  final _shareService = TimetableShareService();
  final _staffroomService = StaffroomService();
  TimetableConfig? _config;
  SchoolRole? _myRole;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await _timetableService.getConfig(widget.school.id);
    final claim = await _schoolService.currentSchoolClaim();
    if (!mounted) return;
    setState(() {
      _config = config;
      _myRole = claim.role;
    });
  }

  bool get _canPin => _myRole?.isLeadership == true || _myRole == SchoolRole.administrator;

  Future<void> _export(List<TimetableAssignment> assignments) async {
    setState(() => _busy = true);
    try {
      await _exportService.exportTeacherPdf(school: widget.school, teacherName: widget.teacherName, assignments: assignments, config: _config!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download started.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pinToStaffroom(List<TimetableAssignment> assignments) async {
    setState(() => _busy = true);
    try {
      await _staffroomService.postPinned(
        schoolId: widget.school.id,
        text: "📅 ${widget.teacherName}'s timetable — ${assignments.length} period${assignments.length == 1 ? '' : 's'}/week. "
            'Open Timetable → By Teacher → ${widget.teacherName} in the app to view it.',
        topic: 'Timetable',
        authorName: widget.teacherName == 'You' ? 'Me' : widget.teacherName,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pinned to Staffroom.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not pin: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareToWhatsApp(List<TimetableAssignment> assignments) async {
    setState(() => _busy = true);
    try {
      final bytes = await _exportService.buildScopedPdfBytes(
        school: widget.school,
        scopeTitle: widget.teacherName,
        assignments: assignments,
        config: _config!,
        cellSubtitle: (a) => a.className,
      );
      final outcome = await _shareService.shareToWhatsApp(bytes: bytes, fileName: '${widget.teacherName}_timetable.pdf', caption: '${widget.school.name} — ${widget.teacherName}\'s timetable');
      if (!mounted) return;
      if (outcome == TimetableShareOutcome.webDownloadedAndWhatsAppOpened) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Downloaded and WhatsApp opened — attach the downloaded file to your chat.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.teacherName),
        actions: [
          StreamBuilder<GeneratedTimetable?>(
            stream: _timetableService.watchGenerated(widget.school.id),
            builder: (context, snapshot) {
              final mine = (snapshot.data?.assignments ?? const <TimetableAssignment>[]).where((a) => a.teacherUid == widget.teacherUid).toList();
              if (mine.isEmpty || _config == null) return const SizedBox.shrink();
              return Row(
                children: [
                  IconButton(icon: const Icon(Icons.ios_share), tooltip: 'Export', onPressed: _busy ? null : () => _export(mine)),
                  if (_canPin) IconButton(icon: const Icon(Icons.push_pin_outlined), tooltip: 'Pin to Staffroom', onPressed: _busy ? null : () => _pinToStaffroom(mine)),
                  IconButton(icon: const Icon(Icons.chat_bubble_outline), tooltip: 'Share to WhatsApp', onPressed: _busy ? null : () => _shareToWhatsApp(mine)),
                ],
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<GeneratedTimetable?>(
        stream: _timetableService.watchGenerated(widget.school.id),
        builder: (context, snapshot) {
          if (!snapshot.hasData || _config == null) return const Center(child: CircularProgressIndicator());
          final mine = (snapshot.data?.assignments ?? const <TimetableAssignment>[]).where((a) => a.teacherUid == widget.teacherUid).toList();
          if (mine.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No timetable periods are assigned to this teacher yet.')),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: TimetableGrid(
              assignments: mine,
              periodsPerDay: _config!.periodsPerDay,
              teachingDaysPerWeek: _config!.teachingDaysPerWeek,
              cellSubtitle: (a) => a.className,
            ),
          );
        },
      ),
    );
  }
}
