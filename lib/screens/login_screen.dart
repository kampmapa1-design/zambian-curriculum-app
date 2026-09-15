import 'package:flutter/material.dart';

import '../services/teacher_auth_service.dart';
import '../services/teacher_cloud_profile_service.dart';
import '../services/teacher_profile_repository.dart';

enum _LoginView { choice, phoneNumber, phoneCode, emailForm }

/// Stage 2 of real phone/email sign-in (2026-09-13) — the choice-based
/// login/sign-up screen: "Continue with Phone Number" or "Continue with
/// Email", each ending at the same authenticated session either way (per
/// explicit request — nothing downstream needs to know which path a
/// teacher used). Reachable from Data Manager → "My Account" for a teacher
/// who's still anonymous and wants School Code/Staffroom-ready identity;
/// nothing about the existing anonymous flow changes for a teacher who
/// never opens this screen at all.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _authService = TeacherAuthService();
  final _profileRepository = TeacherProfileRepository();
  final _cloudProfileService = TeacherCloudProfileService();

  _LoginView _view = _LoginView.choice;
  bool _busy = false;
  String? _error;

  // Phone
  final _phoneController = TextEditingController(text: '+260');
  final _codeController = TextEditingController();
  String? _verificationId;

  // Email
  bool _emailIsSignUp = true;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _finish(TeacherAuthResult result) async {
    final profile = await _profileRepository.load();
    final updated = profile.copyWith(
      loginMethod: loginMethodOf(result.user).name,
      phone: result.user.phoneNumber ?? profile.phone,
      email: result.user.email ?? profile.email,
    );
    await _profileRepository.save(updated);
    try {
      await _cloudProfileService.syncFromAuth(result.user, updated);
    } catch (_) {
      // Best-effort mirror — the on-device profile above is already saved
      // and is what the rest of the app actually relies on today.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.upgradedFromAnonymous
          ? "You're signed in — your existing marking history and lesson progress are still here."
          : "You're signed in."),
    ));
    // Only pop if there's actually a screen to return to — on the web
    // dashboard (added 2026-09-14) this screen IS the app's root while
    // signed out, with no route beneath it; the auth-state StreamBuilder
    // that wraps it there swaps it out for the signed-in view on its own
    // once FirebaseAuth reports the new session, no pop needed.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _sendPhoneCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await _authService.startPhoneVerification(
      phoneNumber: _phoneController.text.trim(),
      onCodeSent: (verificationId) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _verificationId = verificationId;
          _view = _LoginView.phoneCode;
        });
      },
      onAutoVerified: (result) {
        if (!mounted) return;
        _finish(result);
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

  Future<void> _confirmPhoneCode() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _authService.confirmPhoneCode(
        verificationId: _verificationId!,
        smsCode: _codeController.text.trim(),
      );
      await _finish(result);
    } on TeacherAuthError catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitEmailForm() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (_emailIsSignUp && password != _confirmPasswordController.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = _emailIsSignUp
          ? await _authService.signUpWithEmail(email: email, password: password)
          : await _authService.signInWithEmail(email: email, password: password);
      await _finish(result);
    } on TeacherAuthError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Type your email above first, then tap "Forgot password?" again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _authService.sendPasswordResetEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Password reset link sent to $email.')),
      );
    } on TeacherAuthError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_view == _LoginView.choice) ..._buildChoice(),
              if (_view == _LoginView.phoneNumber) ..._buildPhoneNumber(),
              if (_view == _LoginView.phoneCode) ..._buildPhoneCode(),
              if (_view == _LoginView.emailForm) ..._buildEmailForm(),
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

  List<Widget> _buildChoice() => [
        const SizedBox(height: 24),
        const Icon(Icons.school_outlined, size: 56),
        const SizedBox(height: 16),
        Text(
          'Create an account to unlock School Code and Staffroom features later — your marking history and lesson progress on this device come with you.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          icon: const Icon(Icons.phone_outlined),
          label: const Text('Continue with Phone Number'),
          onPressed: () => setState(() {
            _view = _LoginView.phoneNumber;
            _error = null;
          }),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.email_outlined),
          label: const Text('Continue with Email'),
          onPressed: () => setState(() {
            _view = _LoginView.emailForm;
            _error = null;
          }),
        ),
      ];

  List<Widget> _buildPhoneNumber() => [
        IconButton(
          alignment: Alignment.centerLeft,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _view = _LoginView.choice;
            _error = null;
          }),
        ),
        Text('Enter your phone number', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          "Include the country code, e.g. +260 for Zambia. We'll text you a one-time code.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _sendPhoneCode,
          child: _busy ? const _Spinner() : const Text('Send code'),
        ),
      ];

  List<Widget> _buildPhoneCode() => [
        IconButton(
          alignment: Alignment.centerLeft,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _view = _LoginView.phoneNumber;
            _error = null;
          }),
        ),
        Text('Enter the code we sent you', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('Sent to ${_phoneController.text.trim()}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '6-digit code', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _confirmPhoneCode,
          child: _busy ? const _Spinner() : const Text('Confirm'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _sendPhoneCode,
          child: const Text('Resend code'),
        ),
      ];

  List<Widget> _buildEmailForm() => [
        IconButton(
          alignment: Alignment.centerLeft,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _view = _LoginView.choice;
            _error = null;
          }),
        ),
        Text(_emailIsSignUp ? 'Create your account' : 'Sign in', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
        ),
        if (_emailIsSignUp) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _confirmPasswordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Confirm password', border: OutlineInputBorder()),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submitEmailForm,
          child: _busy ? const _Spinner() : Text(_emailIsSignUp ? 'Sign up' : 'Sign in'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _emailIsSignUp = !_emailIsSignUp;
                    _error = null;
                  }),
          child: Text(_emailIsSignUp ? 'Already have an account? Sign in' : "Don't have an account? Sign up"),
        ),
        if (!_emailIsSignUp)
          TextButton(
            onPressed: _busy ? null : _forgotPassword,
            child: const Text('Forgot password?'),
          ),
      ];
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      );
}
