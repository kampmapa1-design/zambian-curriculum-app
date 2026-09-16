import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/home_assignment.dart';
import '../models/school.dart';
import '../services/home_assignment_document_service.dart';
import '../services/home_assignment_marking_key_document_service.dart';
import '../services/home_assignment_service.dart';
import '../services/school_score_entry_service.dart';
import '../services/school_service.dart';

/// Home Assignment epic, Stage 7 — "Send the generated assignment to
/// each learner in the subject teacher's class." Picks from the
/// teacher's OWN real School Network classes for this subject (never a
/// free-text class name), an optional deadline, then dispatches via
/// `sendHomeAssignmentToClass` — email attachment automatic, WhatsApp a
/// real tap-through per recipient (same "server can't open WhatsApp for
/// you" reasoning Broadcast to Guardians already established), and
/// in-app delivery is simply the resulting Firestore doc existing.
class HomeAssignmentSendScreen extends StatefulWidget {
  const HomeAssignmentSendScreen({required this.result, required this.subjectName, required this.markingKeyTitle, super.key});
  final HomeAssignmentResult result;
  final String subjectName;
  final String markingKeyTitle;

  @override
  State<HomeAssignmentSendScreen> createState() => _HomeAssignmentSendScreenState();
}

class _HomeAssignmentSendScreenState extends State<HomeAssignmentSendScreen> {
  final _schoolService = SchoolService();
  final _scoreEntryService = SchoolScoreEntryService();
  final _homeAssignmentService = HomeAssignmentService();
  final _documentService = HomeAssignmentDocumentService();
  final _markingKeyDocumentService = HomeAssignmentMarkingKeyDocumentService();

  bool _loading = true;
  bool _sending = false;
  bool _sharingMarkingKey = false;
  School? _school;
  List<SchoolClass> _eligibleClasses = const [];
  String? _selectedClassId;
  DateTime? _deadline;
  bool _sent = false;
  String? _referenceCode;
  int _emailsSent = 0;
  int _emailsFailed = 0;
  List<({String name, String phone})> _whatsappRecipients = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final school = await _schoolService.getCurrentSchool();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    List<SchoolClass> eligible = const [];
    if (school != null && uid != null) {
      final assigned = await _scoreEntryService.myAssignedClasses(school.id, uid);
      eligible = assigned.where((c) => c.subjectTeacherUids[widget.subjectName] == uid).toList();
    }
    if (!mounted) return;
    setState(() {
      _school = school;
      _eligibleClasses = eligible;
      _selectedClassId = eligible.isNotEmpty ? eligible.first.id : null;
      _loading = false;
    });
  }

  Future<void> _pickDeadline() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 7)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _deadline = picked);
  }

  Future<void> _send() async {
    final school = _school;
    final classId = _selectedClassId;
    if (school == null || classId == null) return;
    final schoolClass = _eligibleClasses.firstWhere((c) => c.id == classId);
    setState(() => _sending = true);
    try {
      final pdfBytes = await _documentService.buildPdf(schoolName: school.name, className: schoolClass.classGrade, result: widget.result);
      final outcome = await _homeAssignmentService.sendToClass(
        schoolId: school.id,
        classId: classId,
        subjectName: widget.subjectName,
        title: widget.result.title,
        instructions: widget.result.instructions,
        questions: widget.result.questions,
        markingKeyTitle: widget.markingKeyTitle,
        markingKey: widget.result.markingKey,
        deadline: _deadline,
        attachmentPdfBytes: pdfBytes,
        attachmentFilename: '${widget.result.title}.pdf',
      );
      if (!mounted) return;
      setState(() {
        _sent = true;
        _referenceCode = outcome.referenceCode;
        _emailsSent = outcome.emailsSent;
        _emailsFailed = outcome.emailsFailed;
        _whatsappRecipients = outcome.whatsappRecipients;
      });
    } on HomeAssignmentException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// "Share out that marking key through the app's sharing means"
  /// (2026-09-16, per explicit request) — the marking key never went to a
  /// pupil either way (it's not part of `sendToClass`'s attachment), so
  /// this is a deliberately separate action from "Send to Class": a
  /// subject teacher shares it with themselves or a co-marker, via
  /// whatever the OS share sheet offers (same `share_plus` pattern used
  /// for marksheets and assignment submissions elsewhere in this app).
  Future<void> _shareMarkingKey() async {
    setState(() => _sharingMarkingKey = true);
    try {
      final bytes = await _markingKeyDocumentService.buildPdf(
        markingKeyTitle: widget.markingKeyTitle,
        subjectName: widget.subjectName,
        result: widget.result,
      );
      final dir = await getTemporaryDirectory();
      final safeName = widget.markingKeyTitle.replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '').trim();
      final file = File(p.join(dir.path, '${safeName.isEmpty ? 'marking_key' : safeName}.pdf'));
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: widget.markingKeyTitle));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share the marking key: $error')));
    } finally {
      if (mounted) setState(() => _sharingMarkingKey = false);
    }
  }

  Future<void> _openWhatsApp(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll('+', '');
    final code = _referenceCode;
    final message = '${widget.result.title} — attaching the assignment next.'
        '${code != null ? '\n\nReference code: $code\nPlease keep this reference code in your reply.' : ''}';
    final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(message)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Home Assignment')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sent
              ? _buildSentView()
              : _buildFormView(),
    );
  }

  Widget _buildFormView() {
    if (_eligibleClasses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text("You're not assigned as the ${widget.subjectName} teacher for any connected class yet — set that up in School Network first.", textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Send "${widget.result.title}" to:', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final c in _eligibleClasses)
          RadioListTile<String>(title: Text(c.classGrade), subtitle: Text(c.term), value: c.id, groupValue: _selectedClassId, onChanged: (v) => setState(() => _selectedClassId = v)),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.event_outlined),
          title: Text(_deadline == null ? 'No deadline set' : 'Due ${_deadline!.day}/${_deadline!.month}/${_deadline!.year}'),
          trailing: TextButton(onPressed: _pickDeadline, child: const Text('Set deadline')),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: _sending ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.send_outlined),
          label: Text(_sending ? 'Sending...' : 'Send to Class'),
          onPressed: _sending ? null : _send,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: _sharingMarkingKey ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.share_outlined),
          label: Text(_sharingMarkingKey ? 'Preparing…' : 'Share Marking Key'),
          onPressed: _sharingMarkingKey ? null : _shareMarkingKey,
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            "For you or a co-marker — the marking key is never sent to pupils, only the assignment itself.",
            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          ),
        ),
      ],
    );
  }

  Widget _buildSentView() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Icon(Icons.check_circle_outline, size: 56, color: Colors.green),
        const SizedBox(height: 12),
        Text('Sent — $_emailsSent email(s) delivered${_emailsFailed > 0 ? ', $_emailsFailed failed' : ''}.', textAlign: TextAlign.center),
        const Text('Linked pupils will also see this in their app automatically.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
        if (_referenceCode != null) ...[
          const SizedBox(height: 8),
          Chip(label: Text('Reference code: $_referenceCode', style: const TextStyle(fontWeight: FontWeight.bold))),
        ],
        if (_whatsappRecipients.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('WhatsApp — tap each to open a chat (attach the PDF you just downloaded):', style: Theme.of(context).textTheme.titleSmall),
          for (final r in _whatsappRecipients)
            ListTile(leading: const Icon(Icons.chat_bubble_outline), title: Text(r.name), subtitle: Text(r.phone), onTap: () => _openWhatsApp(r.phone)),
        ],
        const SizedBox(height: 20),
        OutlinedButton.icon(
          icon: _sharingMarkingKey ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Icon(Icons.share_outlined),
          label: Text(_sharingMarkingKey ? 'Preparing…' : 'Share Marking Key'),
          onPressed: _sharingMarkingKey ? null : _shareMarkingKey,
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst), child: const Text('Done')),
      ],
    );
  }
}
