import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/school.dart';
import '../services/school_broadcast_service.dart';
import '../services/school_service.dart';

/// School Network, Stage 9 (added 2026-09-13, per explicit user
/// confirmation of the guardian-data-sync decision) — "Broadcast to
/// Guardians", reached from the Leadership Dashboard. Only unlocked when
/// [School.institutionalSubscription] is true, exactly as the brief
/// specifies.
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({required this.school, super.key});
  final School school;

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final _broadcastService = SchoolBroadcastService();
  final _subjectController = TextEditingController();
  final _messageController = TextEditingController();
  bool _sending = false;
  String? _error;
  BroadcastResult? _result;

  @override
  void dispose() {
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_subjectController.text.trim().isEmpty || _messageController.text.trim().isEmpty) {
      setState(() => _error = 'Enter both a subject and a message.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = await _broadcastService.broadcast(
        schoolId: widget.school.id,
        subject: _subjectController.text.trim(),
        message: _messageController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on SchoolException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openWhatsApp(BroadcastRecipient recipient) async {
    final digits = recipient.phone.replaceAll(RegExp(r'[^0-9+]'), '').replaceAll('+', '');
    final text = '${_subjectController.text.trim()}: ${_messageController.text.trim()}';
    final uri = Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.school.institutionalSubscription) {
      return Scaffold(
        appBar: AppBar(title: const Text('Broadcast to Guardians')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              "This school doesn't have an institutional subscription yet — broadcast tools unlock once it does.",
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Broadcast to Guardians')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Sends to every guardian contact shared by a Grade Teacher when connecting their class. Email is sent for real; WhatsApp opens one chat at a time for you to tap through after sending.',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _subjectController,
              enabled: result == null,
              decoration: const InputDecoration(labelText: 'Subject', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              enabled: result == null,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Message', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            if (result == null)
              FilledButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Send broadcast'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (result != null) ...[
              const SizedBox(height: 8),
              Text(
                result.emailsFailed > 0
                    ? '${result.emailsSent} email(s) sent, ${result.emailsFailed} failed.'
                    : '${result.emailsSent} email(s) sent.',
              ),
              Text('${result.smsAttempted} SMS attempted (still using a placeholder sender until a real SMS provider is set up).'),
              if (result.whatsappRecipients.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Tap each to open WhatsApp (${result.whatsappRecipients.length}):', style: Theme.of(context).textTheme.titleSmall),
                for (final recipient in result.whatsappRecipients)
                  ListTile(
                    leading: const Icon(Icons.chat_outlined),
                    title: Text('Guardian of ${recipient.name}'),
                    subtitle: Text(recipient.phone),
                    onTap: () => _openWhatsApp(recipient),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
