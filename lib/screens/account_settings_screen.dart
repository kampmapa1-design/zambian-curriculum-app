import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/teacher_auth_service.dart';
import '../services/teacher_profile_repository.dart';
import 'login_screen.dart';

/// "My Account" — reached from Data Manager. Shows a still-anonymous
/// teacher the same choice screen as [LoginScreen]; shows a teacher who's
/// already signed up their identity, plus Stage 6's account-recovery
/// actions ("Forgot Password" lives on the sign-in form itself — this is
/// "Change Phone Number" for a phone account, and a reset-email trigger
/// for an email account).
class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  final _authService = TeacherAuthService();
  final _profileRepository = TeacherProfileRepository();

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final method = loginMethodOf(user);

    if (method == TeacherLoginMethod.anonymous) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Account')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_outline, size: 56),
                const SizedBox(height: 16),
                const Text(
                  "You're using Smart Teacher without an account. Sign up to unlock School Code and Staffroom features later.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  ),
                  child: const Text('Sign up / Sign in'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My Account')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: Icon(method == TeacherLoginMethod.phone ? Icons.phone_outlined : Icons.email_outlined),
            title: Text(method == TeacherLoginMethod.phone ? (user?.phoneNumber ?? '') : (user?.email ?? '')),
            subtitle: Text(method == TeacherLoginMethod.phone ? 'Signed in with phone' : 'Signed in with email'),
          ),
          const Divider(),
          if (method == TeacherLoginMethod.phone)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Change phone number'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const _ChangePhoneNumberScreen()),
              ),
            ),
          if (method == TeacherLoginMethod.email)
            ListTile(
              leading: const Icon(Icons.lock_reset_outlined),
              title: const Text('Reset password'),
              subtitle: const Text('Sends a reset link to your email'),
              onTap: () async {
                final email = user?.email;
                if (email == null) return;
                try {
                  await _authService.sendPasswordResetEmail(email);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Password reset link sent to $email.')),
                  );
                } on TeacherAuthError catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
                }
              },
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text(
                    "You can sign back in any time with the same phone number or email — nothing is deleted.",
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sign out')),
                  ],
                ),
              );
              if (confirmed != true) return;
              await _authService.signOut();
              final profile = await _profileRepository.load();
              await _profileRepository.save(profile.copyWith(loginMethod: 'anonymous', phone: '', email: ''));
              if (!context.mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

class _ChangePhoneNumberScreen extends StatefulWidget {
  const _ChangePhoneNumberScreen();

  @override
  State<_ChangePhoneNumberScreen> createState() => _ChangePhoneNumberScreenState();
}

class _ChangePhoneNumberScreenState extends State<_ChangePhoneNumberScreen> {
  final _authService = TeacherAuthService();
  final _phoneController = TextEditingController(text: '+260');
  final _codeController = TextEditingController();
  String? _verificationId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await _authService.startPhoneNumberChange(
      newPhoneNumber: _phoneController.text.trim(),
      onCodeSent: (verificationId) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _verificationId = verificationId;
        });
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = error.message;
        });
      },
    );
  }

  Future<void> _confirmCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _authService.confirmPhoneNumberChange(
        verificationId: _verificationId!,
        smsCode: _codeController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Phone number updated.')));
      Navigator.of(context).pop();
    } on TeacherAuthError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change phone number')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              enabled: _verificationId == null,
              decoration: const InputDecoration(labelText: 'New phone number', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            if (_verificationId == null)
              FilledButton(
                onPressed: _busy ? null : _sendCode,
                child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Send code'),
              )
            else ...[
              TextField(
                controller: _codeController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '6-digit code', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _confirmCode,
                child: _busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4)) : const Text('Confirm new number'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}
