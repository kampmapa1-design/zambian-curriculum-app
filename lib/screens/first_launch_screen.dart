import 'package:flutter/material.dart';

import '../services/teacher_profile_repository.dart';

/// Home Assignment epic, Stage 1 (added 2026-09-14, revised the same day
/// per direct feedback after the original phone-first design hit a real
/// Play Integrity/reCAPTCHA failure on a release build — see
/// teacher_auth_service.dart's phone path for where that surfaces, and
/// the fix applied to this app's Firebase Android SHA-256 fingerprint,
/// which was the real root cause). Originally this screen also collected
/// a phone number and ran the OTP flow before role selection; that's
/// been removed entirely. What's here now is a single, purely local,
/// no-network question — "Teacher or Pupil?" — so a first launch can
/// NEVER be blocked by an auth/network problem. Real sign-in (phone OR
/// email, via the existing [LoginScreen]) only ever gets asked for later,
/// at the specific point a "subscribed service" actually needs a
/// permanent identity — School Network membership
/// (school_home_screen.dart, timetable_home_screen.dart) and joining a
/// class as a pupil (join_class_pupil_screen.dart) already work this
/// way; nothing else in the app has ever required an account.
///
/// This screen is the app's ROOT while `role` is unset (see main.dart's
/// `_RoleGate`) — there is no screen beneath it to pop back to, so it
/// reports completion via [onDone] instead of `Navigator.pop`, the same
/// shape `_WebAuthGate` already uses for the web dashboard's own
/// signed-out root.
class FirstLaunchScreen extends StatefulWidget {
  const FirstLaunchScreen({required this.onDone, super.key});
  final ValueChanged<AccountRole> onDone;

  @override
  State<FirstLaunchScreen> createState() => _FirstLaunchScreenState();
}

class _FirstLaunchScreenState extends State<FirstLaunchScreen> {
  final _profileRepository = TeacherProfileRepository();
  bool _busy = false;
  AccountRole? _selectedRole;

  Future<void> _finish() async {
    final role = _selectedRole;
    if (role == null) return;
    setState(() => _busy = true);
    final profile = await _profileRepository.load();
    await _profileRepository.save(profile.copyWith(role: role));
    if (!mounted) return;
    widget.onDone(role);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.school_outlined, size: 56),
              const SizedBox(height: 16),
              Text('Welcome to Smart Teacher', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Are you a teacher or a pupil? This decides what you see next — you can sign up with a phone number or email later, only if you need to.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              _RoleCard(
                icon: Icons.school_outlined,
                title: 'Teacher',
                subtitle: 'Lesson plans, schemes of work, marking, and more',
                selected: _selectedRole == AccountRole.teacher,
                onTap: () => setState(() => _selectedRole = AccountRole.teacher),
              ),
              const SizedBox(height: 12),
              _RoleCard(
                icon: Icons.backpack_outlined,
                title: 'Pupil',
                subtitle: 'Submit assignments, tests, and home assignments',
                selected: _selectedRole == AccountRole.pupil,
                onTap: () => setState(() => _selectedRole = AccountRole.pupil),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy || _selectedRole == null ? null : _finish,
                child: _busy
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.icon, required this.title, required this.subtitle, required this.selected, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text(subtitle, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_circle, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
