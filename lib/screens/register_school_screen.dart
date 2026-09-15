import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';

/// Stage 1 of School Network — "Register School". The teacher completing
/// this becomes the school's Head Teacher (see `registerSchool` in
/// index.ts for why); real Zambian provinces only, per the "never
/// fabricate data" rule — no free-text province guessing.
class RegisterSchoolScreen extends StatefulWidget {
  const RegisterSchoolScreen({super.key});

  @override
  State<RegisterSchoolScreen> createState() => _RegisterSchoolScreenState();
}

class _RegisterSchoolScreenState extends State<RegisterSchoolScreen> {
  final _schoolService = SchoolService();
  final _nameController = TextEditingController();
  final _districtController = TextEditingController();
  final _headTeacherController = TextEditingController();
  String? _province;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _districtController.dispose();
    _headTeacherController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameController.text.trim().isEmpty ||
        _province == null ||
        _districtController.text.trim().isEmpty ||
        _headTeacherController.text.trim().isEmpty) {
      setState(() => _error = 'Fill in all fields before registering.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final school = await _schoolService.registerSchool(
        name: _nameController.text.trim(),
        province: _province!,
        district: _districtController.text.trim(),
        headTeacherName: _headTeacherController.text.trim(),
      );
      if (!mounted) return;
      await _showCodeDialog(school);
      if (!mounted) return;
      Navigator.of(context).pop(school);
    } on SchoolException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCodeDialog(School school) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('School registered'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${school.name} is now on Smart Teacher. Share this code with your teachers so they can join:'),
            const SizedBox(height: 16),
            Center(
              child: Text(
                school.code,
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, letterSpacing: 4),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "You've been set as Head Teacher — you can reassign this or add a Deputy from My School later.",
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Got it')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Register School')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.school_outlined, size: 48),
              const SizedBox(height: 12),
              const Text(
                "Register your school once — you'll get a code your colleagues can use to join.",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'School name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _province,
                decoration: const InputDecoration(labelText: 'Province', border: OutlineInputBorder()),
                items: kZambianProvinces.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                onChanged: (value) => setState(() => _province = value),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _districtController,
                decoration: const InputDecoration(labelText: 'District', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _headTeacherController,
                decoration: const InputDecoration(labelText: 'Head Teacher name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Register school'),
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
