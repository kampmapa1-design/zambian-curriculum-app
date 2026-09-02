import 'package:flutter/material.dart';

import '../models/teacher_submission.dart';
import '../services/teacher_dashboard_service.dart';
import 'submission_detail_screen.dart';

/// Teacher Submissions Dashboard (Stages 11-14) — lists every Assignment
/// and Test Submission addressed to the teacher's verified email, with
/// filters and a received-count summary. See TeacherDashboardService's
/// doc comment for the full "lightweight cloud mailbox" security model:
/// this screen never talks to Firestore/Storage except through that one
/// service, and never shows a submission until the device has proven
/// (via a one-time emailed code) that it belongs to the teacher whose
/// mailbox it's reading.
///
/// Deliberately NOT built here (staged separately, 2026-09-02): bulk
/// actions (combined-PDF export, bulk send-to-Marking), a per-student
/// "Remind" nudge, and a read-receipt notification back to the student —
/// each is its own real technical effort (PDF merging; there's no class
/// roster under this lightweight model so "Remind" can only be a class-
/// wide broadcast, not per-student; a read receipt needs new push-
/// notification infrastructure this app doesn't have at all yet).
class TeacherSubmissionsDashboardScreen extends StatefulWidget {
  const TeacherSubmissionsDashboardScreen({super.key, this.dashboardService});

  final TeacherDashboardService? dashboardService;

  @override
  State<TeacherSubmissionsDashboardScreen> createState() => _TeacherSubmissionsDashboardScreenState();
}

class _TeacherSubmissionsDashboardScreenState extends State<TeacherSubmissionsDashboardScreen> {
  late final TeacherDashboardService _service = widget.dashboardService ?? TeacherDashboardService();

  bool _loading = true;
  String? _verifiedEmail;

  // Verification gate state.
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  // Loaded data + filters.
  List<TeacherSubmission> _submissions = [];
  SubmissionKind _kind = SubmissionKind.assignment;
  String? _classFilter;
  String? _subjectFilter;
  String? _titleFilter;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final email = await _service.verifiedEmail();
    if (!mounted) return;
    setState(() {
      _verifiedEmail = email;
      _loading = false;
    });
    if (email != null) await _refresh();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.requestAccessCode(email);
      if (mounted) setState(() => _codeSent = true);
    } on TeacherDashboardUnavailable catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyCode() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    if (email.isEmpty || code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.verifyAccessCode(email: email, code: code);
      if (!mounted) return;
      setState(() {
        _verifiedEmail = email.toLowerCase();
        _busy = false;
      });
      await _refresh();
    } on TeacherDashboardUnavailable catch (e) {
      if (mounted) setState(() => _error = '$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await _service.signOutOfDashboard();
    if (!mounted) return;
    setState(() {
      _verifiedEmail = null;
      _codeSent = false;
      _submissions = [];
      _emailController.clear();
      _codeController.clear();
    });
  }

  Future<void> _refresh() async {
    final email = _verifiedEmail;
    if (email == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await _service.listSubmissions(email);
      if (!mounted) return;
      setState(() {
        _submissions = results;
        _loading = false;
      });
    } on TeacherDashboardUnavailable catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<TeacherSubmission> get _kindFiltered => _submissions.where((s) => s.kind == _kind).toList();

  List<TeacherSubmission> get _filtered => _kindFiltered.where((s) {
        if (_classFilter != null && s.className != _classFilter) return false;
        if (_subjectFilter != null && s.subjectName != _subjectFilter) return false;
        if (_titleFilter != null && s.title != _titleFilter) return false;
        return true;
      }).toList();

  List<String> _distinct(Iterable<String> values) =>
      values.where((v) => v.isNotEmpty).toSet().toList()..sort();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Submissions Dashboard'),
        actions: [
          if (_verifiedEmail != null) IconButton(onPressed: _signOut, icon: const Icon(Icons.logout), tooltip: 'Switch email'),
        ],
      ),
      body: _loading && _verifiedEmail == null
          ? const Center(child: CircularProgressIndicator())
          : _verifiedEmail == null
              ? _buildVerificationGate()
              : _buildDashboard(),
    );
  }

  Widget _buildVerificationGate() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Access your Dashboard', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Every assignment/test a student sends to your email also gets filed here. Enter your email — the '
          'same one your students send to — and we\'ll email you a one-time code to prove it\'s really yours.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _emailController,
          enabled: !_codeSent,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Your Email', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        if (!_codeSent)
          FilledButton(onPressed: _busy ? null : _sendCode, child: Text(_busy ? 'Sending…' : 'Send Code'))
        else ...[
          TextField(
            controller: _codeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '6-Digit Code', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _busy ? null : _verifyCode, child: Text(_busy ? 'Verifying…' : 'Verify')),
          TextButton(onPressed: _busy ? null : _sendCode, child: const Text('Resend code')),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ],
    );
  }

  Widget _buildDashboard() {
    final classes = _distinct(_kindFiltered.map((s) => s.className));
    final subjects = _distinct(_kindFiltered.map((s) => s.subjectName));
    final titles = _distinct(_kindFiltered.map((s) => s.title));
    final filtered = _filtered;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<SubmissionKind>(
            segments: const [
              ButtonSegment(value: SubmissionKind.assignment, label: Text('Assignments')),
              ButtonSegment(value: SubmissionKind.test, label: Text('Tests')),
            ],
            selected: {_kind},
            onSelectionChanged: (selection) => setState(() {
              _kind = selection.first;
              _classFilter = null;
              _subjectFilter = null;
              _titleFilter = null;
            }),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _filterDropdown('Class/Grade', _classFilter, classes, (v) => setState(() => _classFilter = v)),
              _filterDropdown('Subject', _subjectFilter, subjects, (v) => setState(() => _subjectFilter = v)),
              _filterDropdown(
                _kind == SubmissionKind.assignment ? 'Assignment Name' : 'Test Name',
                _titleFilter,
                titles,
                (v) => setState(() => _titleFilter = v),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('${filtered.length} received', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_loading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
          if (!_loading && filtered.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Nothing here yet.')),
          for (final s in filtered)
            Card(
              child: ListTile(
                title: Text(s.title.isEmpty ? '(untitled)' : s.title),
                subtitle: Text('${s.studentName} · ${s.className} · ${s.submittedAt.toLocal().toString().split('.').first}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SubmissionDetailScreen(submission: s, dashboardService: _service)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filterDropdown(String label, String? value, List<String> options, ValueChanged<String?> onChanged) {
    return DropdownMenu<String?>(
      label: Text(label),
      initialSelection: value,
      onSelected: onChanged,
      dropdownMenuEntries: [
        const DropdownMenuEntry(value: null, label: 'All'),
        for (final o in options) DropdownMenuEntry(value: o, label: o),
      ],
    );
  }
}
