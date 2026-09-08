import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/lesson_plan.dart';
import '../models/record_of_work.dart';
import '../models/report_class.dart';
import '../models/scheme_of_work.dart';
import '../services/lesson_checkpoint_repository.dart';
import '../services/topic_search_service.dart';
import '../services/voice_command_resolver.dart';
import '../services/voice_command_service.dart';
import 'class_overview_screen.dart';
import 'generate_lesson_plan_flow.dart';
import 'lesson_plan_screen.dart';
import 'marking_queue_screen.dart';
import 'record_of_work_screen.dart';
import 'scheme_of_work_document_screen.dart';
import 'teaching_notes_sheet.dart';
import 'teaching_resources_menu_screen.dart';

/// "Standby" voice-command capability (2026-09-08, per explicit request,
/// clarified via AskUserQuestion: tap-to-talk, not always-on background
/// listening). Tapping the mic runs entirely on-device speech-to-text
/// (`speech_to_text` — Android's own SpeechRecognizer; no audio is ever
/// recorded to a file or sent anywhere) for ONE short command. Only the
/// resulting TEXT transcript is sent anywhere (to Gemini, via
/// [VoiceCommandService], for intent parsing); [VoiceCommandResolver] then
/// matches that intent against this app's own real data — never a
/// subject/grade/topic/class that wasn't actually there or actually said.
/// The teacher always sees a plain-language confirmation of what was
/// understood before anything is generated or shared.
///
/// Follow-up batch (2026-09-08, per explicit request): a command can now
/// name a topic by real CONTENT ("which topic can I find the parable of
/// talents in") instead of only by number — see [_VoiceState.candidates]
/// and [TopicOutcome.candidates] — and voice can also open the marking
/// assistant, a specific class roster, a CDC new-materials check, or
/// resume the single most recently paused lesson.
class VoiceCommandScreen extends StatefulWidget {
  const VoiceCommandScreen({super.key});

  @override
  State<VoiceCommandScreen> createState() => _VoiceCommandScreenState();
}

enum _VoiceState { idle, listening, understanding, candidates, confirming, error }

class _VoiceCommandScreenState extends State<VoiceCommandScreen> {
  final SpeechToText _speech = SpeechToText();
  final VoiceCommandService _service = VoiceCommandService();
  final VoiceCommandResolver _resolver = VoiceCommandResolver();

  _VoiceState _state = _VoiceState.idle;
  String _transcript = '';
  String _errorMessage = '';
  VoiceCommandOutcome? _resolved;
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
      // A keyword search that couldn't pick one confident topic — show the
      // real ranked candidates as an activatable list instead of guessing.
      if (resolved is TopicOutcome && resolved.candidates != null && resolved.candidates!.isNotEmpty) {
        setState(() {
          _resolved = resolved;
          _state = _VoiceState.candidates;
        });
        return;
      }
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

  /// A teacher activated one of the ranked candidates from
  /// [_VoiceState.candidates] — turns it into a fresh, specific
  /// [TopicOutcome] (candidates cleared) and moves on to the normal
  /// confirm step.
  void _pickCandidate(TopicSearchResult candidate) {
    final current = _resolved;
    if (current is! TopicOutcome) return;
    setState(() {
      _resolved =
          TopicOutcome(parsed: current.parsed, template: current.template, term: candidate.term, entry: candidate.entry);
      _state = _VoiceState.confirming;
    });
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

  // ---- Action handlers ---------------------------------------------------

  /// [VoiceCommandAction.generateLessonPlan] — per explicit request
  /// (2026-09-08), a lesson plan generated by voice now comes paired with
  /// a detailed teaching-notes bulletin for the same topic BY DEFAULT,
  /// rather than needing a separate manual trip to Teaching Notes.
  /// Deliberately does NOT pop this screen before starting the flow (see
  /// this method's own inline note) so the follow-up notes step below
  /// still has a real, mounted [context] to work with once the whole
  /// nested lesson-plan flow finishes and control returns here.
  Future<void> _generateLessonPlanWithNotes(TopicOutcome resolved) async {
    // Left on the navigation stack (not popped first, unlike every other
    // action here) specifically so the bulletin-notes step below still has
    // a valid, mounted context to open a sheet from once this returns —
    // popping first (like the other single-step actions do) would risk
    // using a long-since-deactivated context after this potentially
    // long-running nested flow (several dialogs, a full lesson plan
    // screen) finally completes. Popped once, at the very end, below.
    await startGenerateLessonPlanFlow(context, resolved.template, initialEntry: resolved.entry);
    if (!mounted) return;
    // Known simplification, disclosed rather than hidden: there's no
    // signal here for "the teacher cancelled partway through" vs.
    // "finished and shared the lesson plan" — startGenerateLessonPlanFlow
    // returns the same way either way. Showing the notes bulletin
    // regardless is low-friction (a dismissible sheet, nothing sent
    // anywhere until the teacher taps Share inside it), so it errs toward
    // "offer it" rather than risk silently skipping the default the
    // teacher asked for.
    if (resolved.entry != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Here is a detailed teaching notes bulletin for this topic too — share it below.')),
      );
      await showTeachingNotesSheet(context, entry: resolved.entry!, template: resolved.template, initialFormat: 'bullet');
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _generateSchemeOfWork(TopicOutcome resolved) async {
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
      builder: (_) => SchemeOfWorkDocumentScreen(template: resolved.template, entries: entries, targetTerm: resolved.term),
    ));
  }

  Future<void> _generateRecordOfWork(TopicOutcome resolved) async {
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
  }

  Future<void> _generateNotesOnly(TopicOutcome resolved) async {
    if (resolved.entry == null) {
      _showCouldNotFullyResolve(
        'Found "${resolved.template.subject.name} — ${resolved.template.grade.name}", but not a specific '
        'topic — open Generate Teaching Notes & Slides from the home screen to pick one.',
      );
      return;
    }
    Navigator.of(context).pop();
    await showTeachingNotesSheet(context, entry: resolved.entry!, template: resolved.template);
  }

  Future<void> _openClassRoster(ClassRosterOutcome resolved) async {
    var target = resolved.matchedClass;
    if (target == null) {
      if (resolved.allClasses.isEmpty) {
        _showCouldNotFullyResolve('No classes set up yet in Data Manager — create one there first.');
        return;
      }
      final picked = await showDialog<ReportClass>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Which class?'),
          children: [
            for (final c in resolved.allClasses)
              SimpleDialogOption(onPressed: () => Navigator.of(dialogContext).pop(c), child: Text(c.label)),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      target = picked;
    }
    Navigator.of(context).pop();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ClassOverviewScreen(reportClass: target!)));
  }

  Future<void> _openCdcMaterials() async {
    Navigator.of(context).pop();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TeachingResourcesMenuScreen()));
  }

  Future<void> _resumeLesson(ResumeLessonOutcome resolved) async {
    final checkpoint = resolved.checkpoint;
    if (checkpoint == null) {
      _showCouldNotFullyResolve('Nothing is currently paused — start a new lesson plan instead.');
      return;
    }
    final template = resolved.template;
    final entry = resolved.entry;
    if (template == null || entry == null) {
      _showCouldNotFullyResolve("Found a paused lesson, but its subject/topic couldn't be loaded anymore.");
      return;
    }
    final activeTemplate =
        template.curriculum.code == 'CBC_2023' ? defaultCbcLessonPlanTemplate : defaultCdcLessonPlanTemplate;
    Navigator.of(context).pop();
    // LessonPlanScreen's own initState finds this same checkpoint again
    // (by curriculum/subject/grade/topic) and asks "Resume this lesson?",
    // showing the real stage it was left at — same as every other resume
    // entry point in this app (see generate_lesson_plan_flow.dart).
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LessonPlanScreen(
        subjectName: template.subject.name,
        curriculumCode: template.curriculum.code,
        subjectCode: template.subject.code,
        gradeLevel: template.grade.level,
        entry: entry,
        template: activeTemplate,
        checkpointRepository: LessonCheckpointRepository(),
        isOneOff: checkpoint.isOneOff,
      ),
    ));
  }

  Future<void> _openMarking() async {
    Navigator.of(context).pop();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MarkingQueueScreen()));
  }

  Future<void> _confirmDirectAction() async {
    final resolved = _resolved;
    if (resolved == null) return;
    switch (resolved) {
      case TopicOutcome o:
        switch (o.parsed.action) {
          case VoiceCommandAction.generateLessonPlan:
            await _generateLessonPlanWithNotes(o);
            return;
          case VoiceCommandAction.generateSchemeOfWork:
            await _generateSchemeOfWork(o);
            return;
          case VoiceCommandAction.generateRecordOfWork:
            await _generateRecordOfWork(o);
            return;
          case VoiceCommandAction.generateTeachingNotes:
            await _generateNotesOnly(o);
            return;
          case VoiceCommandAction.findTopic:
          case VoiceCommandAction.openMarking:
          case VoiceCommandAction.openClassRoster:
          case VoiceCommandAction.checkCdcMaterials:
          case VoiceCommandAction.resumeLesson:
          case VoiceCommandAction.unrecognized:
            return; // findTopic uses its own 3-button confirm UI, not this single-Confirm path.
        }
      case ClassRosterOutcome o:
        await _openClassRoster(o);
        return;
      case CdcCheckOutcome _:
        await _openCdcMaterials();
        return;
      case ResumeLessonOutcome o:
        await _resumeLesson(o);
        return;
      case MarkingOutcome _:
        await _openMarking();
        return;
    }
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice Command')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(child: _buildBody(context)),
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
          helper: 'e.g. "make a lesson plan for topic number two in week 8 in Civic Education grade 10", '
              '"which topic can I find the parable of talents in RE 2046", "continue where I left off", or '
              '"open my Grade 10A roster".',
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
      case _VoiceState.candidates:
        return _buildCandidates(context);
      case _VoiceState.confirming:
        return _buildConfirming(context);
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

  Widget _buildCandidates(BuildContext context) {
    final resolved = _resolved;
    if (resolved is! TopicOutcome || resolved.candidates == null) return const SizedBox.shrink();
    final keyword = resolved.parsed.topicKeyword ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'A few topics in "${resolved.template.subject.name} — ${resolved.template.grade.name}" mention '
          '"$keyword" — which one?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        for (final candidate in resolved.candidates!)
          Card(
            child: ListTile(
              title: Text(candidate.entry.title),
              subtitle: Text(candidate.term.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickCandidate(candidate),
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _reset, child: const Text('Try Again')),
      ],
    );
  }

  Widget _buildConfirming(BuildContext context) {
    final resolved = _resolved;
    if (resolved == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_outline, size: 48, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(resolved.parsed.summary, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(_confirmingSubtitle(resolved), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 24),
        ..._confirmingActions(resolved),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _reset, child: const Text('Try Again')),
      ],
    );
  }

  String _confirmingSubtitle(VoiceCommandOutcome resolved) => switch (resolved) {
        TopicOutcome o =>
          '${o.template.subject.name} — ${o.template.grade.name}${o.entry != null ? ' — ${o.entry!.title}' : ''}',
        ClassRosterOutcome o => o.matchedClass != null
            ? o.matchedClass!.label
            : (o.allClasses.isEmpty ? 'No classes set up yet' : 'Which class did you mean?'),
        CdcCheckOutcome o => o.unseenCount == 0
            ? (o.parsed.subjectName != null ? 'Nothing new for "${o.parsed.subjectName}" right now' : 'Nothing new right now')
            : '${o.unseenCount} new material${o.unseenCount == 1 ? '' : 's'} queued'
                '${o.parsed.subjectName != null ? ' for "${o.parsed.subjectName}"' : ''}',
        ResumeLessonOutcome o => o.checkpoint == null
            ? 'Nothing paused right now'
            : o.template != null
                ? '${o.template!.subject.name} — ${o.template!.grade.name}${o.entry != null ? ' — ${o.entry!.title}' : ''}'
                : 'A paused lesson was found, but could not be reloaded',
        MarkingOutcome o => o.matchedScheme != null
            ? 'Found your marking key: "${o.matchedScheme!.title}" — pick it when prompted inside Scan Marker.'
            : [o.parsed.subjectName, o.parsed.gradeName].whereType<String>().join(' — '),
      };

  /// Builds the real, tappable buttons for whichever outcome this is —
  /// [TopicOutcome] with a [VoiceCommandAction.findTopic] gets three
  /// (Lesson Plan + Notes / Scheme of Work / Notes Only, per explicit
  /// request) since it's a pure lookup with no single obvious next step;
  /// every other outcome gets exactly one Confirm button, since its own
  /// action already says what to do.
  List<Widget> _confirmingActions(VoiceCommandOutcome resolved) {
    if (resolved is TopicOutcome && resolved.parsed.action == VoiceCommandAction.findTopic) {
      if (resolved.entry == null) {
        return [
          Text(
            'Found the subject, but not a specific topic to act on.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ];
      }
      return [
        FilledButton.icon(
          onPressed: () => _generateLessonPlanWithNotes(resolved),
          icon: const Icon(Icons.assignment_outlined),
          label: const Text('Lesson Plan + Notes Bulletin'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _generateSchemeOfWork(resolved),
          icon: const Icon(Icons.event_note_outlined),
          label: const Text('Scheme of Work'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _generateNotesOnly(resolved),
          icon: const Icon(Icons.notes_outlined),
          label: const Text('Teaching Notes Only'),
        ),
      ];
    }
    return [
      FilledButton(onPressed: _confirmDirectAction, child: const Text('Confirm')),
    ];
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
