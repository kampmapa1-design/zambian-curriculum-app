import 'package:flutter/material.dart';

import '../models/minutes_session.dart';
import '../services/minutes_session_repository.dart';
import 'minutes_capture_screen.dart';

/// Admin Tools — Minutes Maker hub (Stage 4). Every captured meeting-notes
/// session sits here, queued locally, until Stage 5 (AI reconstruction —
/// not built yet) can process it. Mirrors MarkingQueueScreen's hub
/// pattern: a list of what's captured, an "Add" action to capture more.
class MinutesMakerScreen extends StatefulWidget {
  const MinutesMakerScreen({super.key, this.repository});

  final MinutesSessionRepository? repository;

  @override
  State<MinutesMakerScreen> createState() => _MinutesMakerScreenState();
}

class _MinutesMakerScreenState extends State<MinutesMakerScreen> {
  late final MinutesSessionRepository _repository = widget.repository ?? MinutesSessionRepository();

  List<MinutesSession> _sessions = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _repository.loadCatalog();
    if (!mounted) return;
    setState(() {
      _sessions = catalog.sessions.toList()..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
      _loading = false;
    });
  }

  Future<void> _addSession() async {
    final saved = await Navigator.of(context).push<MinutesSession>(
      MaterialPageRoute(builder: (_) => MinutesCaptureScreen(repository: _repository)),
    );
    if (saved != null && mounted) await _load();
  }

  Future<void> _deleteSession(MinutesSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete these notes?'),
        content: Text('"${session.meetingTitle}" (${session.pageCount} page(s)) will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.remove(session);
    if (mounted) await _load();
  }

  String _formatDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Minutes Maker')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addSession,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('Add Meeting Notes'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.groups_outlined, size: 64),
                        const SizedBox(height: 16),
                        const Text(
                          'Photograph handwritten meeting notes — fully offline. Nothing is sent anywhere '
                          'until you choose to process a set of notes into formatted minutes.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '(AI reconstruction into formatted minutes is coming in the next update.)',
                          style: Theme.of(context).textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.groups_outlined),
                        title: Text(session.meetingTitle),
                        subtitle: Text(
                          '${_formatDate(session.meetingDate)} · ${session.pageCount} page(s) · ${session.status.label}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete',
                          onPressed: () => _deleteSession(session),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
