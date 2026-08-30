import 'dart:io';

import 'package:document_camera_frame/document_camera_frame.dart';
import 'package:flutter/material.dart';

import '../models/minutes_session.dart';
import '../services/minutes_session_repository.dart';

/// Minutes Maker, Stage 4 — offline capture. A user photographs handwritten
/// meeting notes (several pages) in a single session: enter the meeting's
/// details once, then capture each page in turn. Deliberately mirrors
/// BurstCaptureScreen's proven capture loop (same DocumentCameraFrame
/// config, same double-pop-avoidance — see that screen's own comment for
/// why onDocumentSaved is never paired with a manual Navigator.pop) rather
/// than sharing the widget itself, since the two screens' metadata forms
/// are genuinely different (marking needs student/subject/gender; a
/// meeting just needs a title and date).
///
/// Nothing is sent anywhere at capture time — the saved session queues
/// locally (see MinutesSessionRepository) until the user explicitly
/// chooses to process it (Stage 5), which is the only point a connection
/// is needed.
class MinutesCaptureScreen extends StatefulWidget {
  const MinutesCaptureScreen({super.key, this.repository});

  final MinutesSessionRepository? repository;

  @override
  State<MinutesCaptureScreen> createState() => _MinutesCaptureScreenState();
}

class _MinutesCaptureScreenState extends State<MinutesCaptureScreen> {
  late final MinutesSessionRepository _repository = widget.repository ?? MinutesSessionRepository();

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  DateTime _meetingDate = DateTime.now();

  bool _sessionStarted = false;
  bool _saving = false;
  final List<File> _capturedPages = [];

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _meetingDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _meetingDate = picked);
  }

  void _startSession() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _sessionStarted = true);
    _captureNextPage();
  }

  Future<void> _captureNextPage() async {
    final result = await Navigator.of(context).push<DocumentCaptureData>(
      MaterialPageRoute(
        builder: (_) => DocumentCameraFrame(
          frameWidth: 320,
          frameHeight: 440,
          requireBothSides: false,
          enableAutoCapture: true,
          showCloseButton: true,
          imageQuality: 75,
          bottomHintText: 'Page ${_capturedPages.length + 1} — hold the notes flat and steady',
          // No onDocumentSaved here — the plugin already pops itself with
          // the result; also popping here double-pops the navigator. See
          // BurstCaptureScreen for the full story on this bug.
        ),
      ),
    );

    if (result == null || !result.hasFrontSide || result.frontImagePath == null) {
      if (_capturedPages.isEmpty && mounted) setState(() => _sessionStarted = false);
      return;
    }

    if (!mounted) return;
    setState(() => _capturedPages.add(File(result.frontImagePath!)));
  }

  Future<void> _finishAndSave() async {
    if (_capturedPages.isEmpty) return;
    setState(() => _saving = true);
    try {
      final session = await _repository.saveSession(
        meetingTitle: _titleController.text.trim(),
        meetingDate: _meetingDate,
        capturedPageFiles: _capturedPages,
      );
      if (!mounted) return;
      Navigator.of(context).pop<MinutesSession>(session);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save these notes: $error')),
      );
      setState(() => _saving = false);
    }
  }

  void _removePage(int index) => setState(() => _capturedPages.removeAt(index));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture Meeting Notes')),
      body: _sessionStarted ? _buildCaptureSession(context) : _buildDetailsForm(context),
    );
  }

  Widget _buildDetailsForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Whose meeting notes are these?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              "Enter the meeting's details now, before capturing pages.",
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Meeting title',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _pickDate,
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Meeting date', border: OutlineInputBorder()),
                child: Text('${_meetingDate.year}-${_meetingDate.month.toString().padLeft(2, '0')}-'
                    '${_meetingDate.day.toString().padLeft(2, '0')}'),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _startSession,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Start Capturing Pages'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureSession(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _titleController.text.trim(),
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Chip(label: Text('${_capturedPages.length} page(s)')),
            ],
          ),
        ),
        Expanded(
          child: _capturedPages.isEmpty
              ? const Center(child: Text('No pages captured yet.'))
              : GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: _capturedPages.length,
                  itemBuilder: (context, index) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(_capturedPages[index], fit: BoxFit.cover),
                      ),
                      Positioned(
                        top: 4,
                        left: 4,
                        child: CircleAvatar(
                          radius: 12,
                          backgroundColor: Colors.black54,
                          child: Text('${index + 1}', style: const TextStyle(fontSize: 12, color: Colors.white)),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                          onPressed: _saving ? null : () => _removePage(index),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _captureNextPage,
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: const Text('Capture Next Page'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_saving || _capturedPages.isEmpty) ? null : _finishAndSave,
                    icon: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check),
                    label: Text(_saving ? 'Saving…' : 'Finish & Save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
