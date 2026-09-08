import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/record_of_work.dart';
import '../models/scheme_of_work.dart';
import '../services/voice_command_resolver.dart';
import '../services/voice_command_service.dart';
import 'generate_lesson_plan_flow.dart';
import 'record_of_work_screen.dart';
import 'scheme_of_work_document_screen.dart';
import 'teaching_notes_sheet.dart';

/// "Standby" voice-command capability (2026-09-08, per explicit request,
/// clarified via AskUserQuestion): tap-to-talk, not always-on background
/// listening. Tapping the mic runs entirely on-device speech-to-text
/// (`speech_to_text` — Android's own SpeechRecognizer; no audio is ever
/// recorded to a file or sent anywhere) for ONE short command, e.g. "make
/// a lesson plan for topic number two in week 8 in the subject of Civic
/// Education grade 10". Only the resulting TEXT transcript is sent
/// anywhere (to Gemini, via [VoiceCommandService], for intent parsing);
/// [VoiceCommandResolver] then matches that intent against this app's own
/// real bundled data — never a subject/grade/topic that wasn't actually
/// bundled or actually said. The teacher always sees a plain-language
/// confirmation of what was understood before anything is generated.
class VoiceCommandScreen extends StatefulWidget {
  const VoiceCommandScreen({super.key});

  @override
  State<VoiceCommandScreen> createState() => _VoiceCommandScreenState();
}

enum _VoiceState { idle, listening, understanding, confirming, error }

class _VoiceCommandScreenState extends State<VoiceCommandScreen> {
  final SpeechToText _speech = SpeechToText();
  final VoiceCommandService _service = VoiceCommandService();
  final VoiceCommandResolver _resolver = VoiceCommandResolver();

  _VoiceState _state = _VoiceState.idle;
  String _transcript = '';
  String _errorMessage = '';
  ResolvedVoiceCommand? _resolved;
  bool _speechAvailable = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _state = _VoiceState.error;
          _errorMessage = 'Speech recognition error: ${error.errorMsg}';
        });
      },
      onStatus: (status) {
        if (status == 'done' && mounted && _state == _VoiceState.listening) {
          _onListeningStopped();
        }
      },
    );
    if (!mounted) return;
    setState(() => _speechAvailable = available);
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  Future<void> _startListening() async {
    if (!_speechAvailable) {
      setState(() {
        _state = _VoiceState.error;
        _errorMessage = 'Speech recognition is not available on this device (or the microphone permission was '
            "denied) — you can still use every other function normally, just not by voice.";
      });
      return;
    }
    setState(() {
      _state = _VoiceState.listening;
      _transcript = '';
      _errorMessage = '';
    });
    await _speech.listen(
      onResult: (result) => setState(() => _transcript = result.recognizedWords),
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.confirmation,
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _onListeningStopped() async {
    if (_transcript.trim().isEmpty) {
      setState(() {
        _state = _VoiceState.error;
        _errorMessage = "Didn't catch anything — tap the mic and try again.";
      });
      return;
    }
    setState(() => _state = _VoiceState.understanding);
    try {
      final parsed = await _service.parse(_transcript.trim());
      if (parsed.action == VoiceCommandAction.unrecognized) {
        if (!mounted) return;
        setState(() {
          _state = _VoiceState.error;
          _errorMessage = parsed.summary;
        });
        return;
      }
      final resolved = await _resolver.resolve(parsed);
      if (!mounted) return;
      setState(() {
        _resolved = resolved;
        _state = _VoiceState.confirming;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _VoiceState.error;
        _errorMessage = '$error';
      });
    }
  }

  Future<void> _confirm() async {
    final resolved = _resolved;
    if (resolved == null) return;
    switch (resolved.parsed.action) {
      case VoiceCommandAction.generateLessonPlan:
        Navigator.of(context).pop();
        await startGenerateLessonPlanFlow(context, resolved.template, initialEntry: resolved.entry);
        return;
      case VoiceCommandAction.generateSchemeOfWork:
        if (resolved.entry == null) {
          _showCouldNotFullyResolve(
            'Found "${resolved.template.subject.name} — ${resolved.template.grade.name}", but not a specific '
            'topic/week — open Generate Scheme of Work from the home screen to pick one.',
          );
          return;
        }
        final entries = generateSchemeOfWorkStartingAt(resolved.template, resolved.entry!);
        Navigator.of(context).pop();
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => SchemeOfWorkDocumentScreen(
            template: resolved.template,
            entries: entries,
            targetTerm: resolved.term,
          ),
        ));
        return;
      case VoiceCommandAction.generateRecordOfWork:
        final period = await showDialog<RecordOfWorkPeriod>(
          context: context,
          builder: (dialogContext) => SimpleDialog(
            title: const Text('Generate Record of Work'),
            children: [
              for (final p in RecordOfWorkPeriod.values)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(dialogContext).pop(p),
                  child: Text(p.label),
                ),
            ],
          ),
        );
        if (period == null || !mounted) return;
        Navigator.of(context).pop();
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RecordOfWorkScreen(template: resolved.template, period: period),
        ));
        return;
      case VoiceCommandAction.generateTeachingNotes:
        if (resolved.entry == null) {
          _showCouldNotFullyResolve(
            'Found "${resolved.template.subject.name} — ${resolved.template.grade.name}", but not a specific '
            'topic — open Generate Teaching Notes & Slides from the home screen to pick one.',
          );
          return;
        }
        Navigator.of(context).pop();
        await showTeachingNotesSheet(context, entry: resolved.entry!, template: resolved.template);
        return;
      case VoiceCommandAction.unrecognized:
        return;
    }
  }

  void _showCouldNotFullyResolve(String message) {
    setState(() {
      _state = _VoiceState.error;
      _errorMessage = message;
    });
  }

  void _reset() {
    setState(() {
      _state = _VoiceState.idle;
      _transcript = '';
      _errorMessage = '';
      _resolved = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice Command')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_state) {
      case _VoiceState.idle:
        return _MicPrompt(
          onTap: _startListening,
          label: 'Tap and speak a command',
          helper: 'e.g. "make a lesson plan for topic number two in week 8 in the subject of Civic Education '
              'grade 10"',
        );
      case _VoiceState.listening:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MicPrompt(onTap: _speech.stop, label: 'Listening… tap to stop', listening: true),
            const SizedBox(height: 20),
            Text(_transcript.isEmpty ? '…' : _transcript, textAlign: TextAlign.center),
          ],
        );
      case _VoiceState.understanding:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Understanding…'),
          ],
        );
      case _VoiceState.confirming:
        final resolved = _resolved!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(resolved.parsed.summary, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '${resolved.template.subject.name} — ${resolved.template.grade.name}'
              '${resolved.entry != null ? ' — ${resolved.entry!.title}' : ''}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(onPressed: _reset, child: const Text('Try Again')),
                const SizedBox(width: 12),
                FilledButton(onPressed: _confirm, child: const Text('Confirm')),
              ],
            ),
          ],
        );
      case _VoiceState.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 12),
            Text(_errorMessage, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: _reset, child: const Text('Try Again')),
          ],
        );
    }
  }
}

class _MicPrompt extends StatelessWidget {
  const _MicPrompt({required this.onTap, required this.label, this.helper, this.listening = false});

  final VoidCallback onTap;
  final String label;
  final String? helper;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(60),
          child: CircleAvatar(
            radius: 48,
            backgroundColor:
                listening ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.primaryContainer,
            child: Icon(
              listening ? Icons.mic : Icons.mic_none,
              size: 44,
              color: listening ? Theme.of(context).colorScheme.onErrorContainer : Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        if (helper != null) ...[
          const SizedBox(height: 8),
          Text(helper!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}
