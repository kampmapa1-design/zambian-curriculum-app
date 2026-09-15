import 'package:flutter/material.dart';

import '../services/pupil_class_link_service.dart';
import '../services/teacher_auth_service.dart';
import 'login_screen.dart';

enum _Step { signIn, code, pickClass, name, requested }

/// Home Assignment epic, Stage 1/7/8 (added 2026-09-14, sign-in step
/// added the same day per direct feedback) — a Pupil-role account's own
/// "join a class" flow: sign up with a phone number or email (only
/// asked for HERE, not at first launch — see FirstLaunchScreen's own
/// doc comment) → school code (same code a teacher uses) → pick the
/// class → confirm their own name from that class's real roster. This
/// only ever CREATES a request (see `requestPupilClassLink`) — a real
/// teacher must confirm it before anything is actually linked, per the
/// explicit decision to keep a human in the loop. Sign-in is required
/// before that request at all, since a join tied to a still-anonymous
/// session could be lost on reinstall — same reasoning
/// school_home_screen.dart already applies to teachers joining a school.
class JoinClassPupilScreen extends StatefulWidget {
  const JoinClassPupilScreen({super.key});

  @override
  State<JoinClassPupilScreen> createState() => _JoinClassPupilScreenState();
}

class _JoinClassPupilScreenState extends State<JoinClassPupilScreen> {
  final _linkService = PupilClassLinkService();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();

  _Step _step = _Step.signIn;
  bool _busy = false;
  String? _error;
  String _schoolName = '';
  List<({String id, String classGrade, String term})> _classes = const [];
  String? _selectedClassId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSignedIn());
  }

  void _checkSignedIn() {
    if (TeacherAuthService().currentLoginMethod != TeacherLoginMethod.anonymous) {
      setState(() => _step = _Step.code);
    }
  }

  Future<void> _signIn() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
    if (mounted) _checkSignedIn();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _lookUpSchool() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _linkService.listClassesByCode(code);
      if (!mounted) return;
      setState(() {
        _schoolName = result.schoolName;
        _classes = result.classes;
        _step = _Step.pickClass;
      });
    } on PupilClassLinkException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitRequest() async {
    final classId = _selectedClassId;
    final name = _nameController.text.trim();
    if (classId == null || name.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _linkService.requestLink(schoolCode: _codeController.text.trim(), classId: classId, learnerName: name);
      if (!mounted) return;
      setState(() => _step = _Step.requested);
    } on PupilClassLinkException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join a Class')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_step == _Step.signIn) ..._buildSignInStep(),
              if (_step == _Step.code) ..._buildCodeStep(),
              if (_step == _Step.pickClass) ..._buildPickClassStep(),
              if (_step == _Step.name) ..._buildNameStep(),
              if (_step == _Step.requested) ..._buildRequestedStep(),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSignInStep() => [
        const Icon(Icons.person_outline, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Create an account first — joining a class is tied to your identity, so it survives even if you reinstall the app. You can use a phone number or email.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _signIn, child: const Text('Sign up / Sign in')),
      ];

  List<Widget> _buildCodeStep() => [
        const Icon(Icons.school_outlined, size: 56),
        const SizedBox(height: 16),
        const Text('Enter your school code — ask your teacher for it.', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        TextField(
          controller: _codeController,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'School code', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _lookUpSchool,
          child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Continue'),
        ),
      ];

  List<Widget> _buildPickClassStep() => [
        Text(_schoolName, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('Which class are you in?', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        if (_classes.isEmpty) const Text('This school has no classes set up yet.', textAlign: TextAlign.center),
        for (final c in _classes)
          RadioListTile<String>(
            title: Text(c.classGrade),
            subtitle: Text(c.term),
            value: c.id,
            groupValue: _selectedClassId,
            onChanged: (v) => setState(() => _selectedClassId = v),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _selectedClassId == null ? null : () => setState(() => _step = _Step.name),
          child: const Text('Continue'),
        ),
      ];

  List<Widget> _buildNameStep() => [
        const Text('What is your name, exactly as it appears on your class register?', textAlign: TextAlign.center),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Your full name', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your teacher will confirm this before it takes effect.',
          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submitRequest,
          child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Send join request'),
        ),
      ];

  List<Widget> _buildRequestedStep() => [
        const Icon(Icons.check_circle_outline, size: 56, color: Colors.green),
        const SizedBox(height: 16),
        const Text('Request sent — ask your teacher to confirm it, then come back here.', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ];
}
