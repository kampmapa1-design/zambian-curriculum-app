import 'package:flutter/material.dart';

import '../services/school_service.dart';
import '../services/teacher_profile_repository.dart';

/// Stage 2 of School Network — "Join School" by code. Joins with role
/// 'teacher' by default; leadership can promote from there (Stage 3).
class JoinSchoolScreen extends StatefulWidget {
  const JoinSchoolScreen({super.key});

  @override
  State<JoinSchoolScreen> createState() => _JoinSchoolScreenState();
}

class _JoinSchoolScreenState extends State<JoinSchoolScreen> {
  final _schoolService = SchoolService();
  final _profileRepository = TeacherProfileRepository();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefillName();
  }

  Future<void> _prefillName() async {
    final profile = await _profileRepository.load();
    if (profile.name.isNotEmpty && mounted) {
      _nameController.text = profile.name;
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_codeController.text.trim().isEmpty || _nameController.text.trim().isEmpty) {
      setState(() => _error = 'Enter both the school code and your name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final school = await _schoolService.joinSchool(code: _codeController.text.trim(), name: _nameController.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("You've joined ${school.name}.")));
      Navigator.of(context).pop(school);
    } on SchoolException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join School')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.groups_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('Ask your Head Teacher or a colleague for your school\'s code.', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'School code', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Join school'),
              ),
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
}
