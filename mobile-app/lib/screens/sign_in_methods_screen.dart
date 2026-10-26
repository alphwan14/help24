import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../theme/app_icons.dart';
import '../utils/auth_error_mapper.dart';
import '../utils/kenyan_phone.dart';

/// Every way into THIS account, and a way to add the ones it lacks.
///
/// WHY IT EXISTS
/// A credential is not an account. Google, email-and-password and phone are
/// three doors into one Help24 account — but until this screen there was no
/// way to see which doors an account had, or to add one. Someone who signed up
/// with Google and later typed their email on a new phone found a door that
/// did not open; someone who used their phone number got a brand-new account
/// and a brand-new life, their jobs and chats left on the old one.
///
/// Adding a method LINKS it to the signed-in account (same uid, same profile,
/// same history). It never signs in with it: a door that already belongs to a
/// different account is refused by Firebase and explained here, never used to
/// switch accounts. Removing a method is deliberately not offered yet — the
/// last door must never be removable, and that rule wants its own review.
class SignInMethodsScreen extends StatefulWidget {
  const SignInMethodsScreen({super.key});

  @override
  State<SignInMethodsScreen> createState() => _SignInMethodsScreenState();
}

class _SignInMethodsScreenState extends State<SignInMethodsScreen> {
  void _showFailure(AuthFailure? failure) {
    if (failure == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${failure.title}. ${failure.message}')),
    );
  }

  void _showDone(String what) {
    if (!mounted) return;
    setState(() {}); // providerData changed; re-read the method list
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what added. You can now sign in with it on any device.')),
    );
  }

  Future<void> _addGoogle(AuthProvider auth) async {
    final ok = await auth.linkGoogle();
    if (ok) {
      _showDone('Google');
    } else {
      _showFailure(auth.failure); // null when the chooser was simply dismissed
    }
  }

  Future<void> _addPassword(AuthProvider auth) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChangeNotifierProvider.value(
        value: auth,
        child: _AddPasswordSheet(initialEmail: AuthService.currentFirebaseUser?.email ?? ''),
      ),
    );
    if (added == true) _showDone('Email and password');
  }

  Future<void> _addPhone(AuthProvider auth) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ChangeNotifierProvider.value(value: auth, child: const _AddPhoneSheet()),
    );
    if (added == true) _showDone('Phone number');
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = AuthService.currentFirebaseUser;
    final email = user?.email;
    final phone = user?.phoneNumber;

    return Scaffold(
      appBar: AppBar(title: const Text('Sign-in methods')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'These are the ways you can sign in to this Help24 account. Adding one keeps everything — '
            'your jobs, chats and payments — on the same account.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          _MethodRow(
            icon: AppIcons.account,
            title: 'Google',
            connected: AuthService.hasGoogle,
            detail: AuthService.hasGoogle ? email : null,
            busy: auth.isLoading,
            onAdd: () => _addGoogle(auth),
          ),
          _MethodRow(
            icon: AppIcons.email,
            title: 'Email and password',
            connected: AuthService.hasPassword,
            detail: AuthService.hasPassword ? email : null,
            busy: auth.isLoading,
            onAdd: () => _addPassword(auth),
          ),
          _MethodRow(
            icon: AppIcons.call,
            title: 'Phone number',
            connected: AuthService.hasPhone,
            detail: AuthService.hasPhone && phone != null ? KenyanPhone.maskE164(phone) : null,
            busy: auth.isLoading,
            onAdd: () => _addPhone(auth),
          ),
        ],
      ),
    );
  }
}

class _MethodRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool connected;
  final String? detail;
  final bool busy;
  final VoidCallback onAdd;

  const _MethodRow({
    required this.icon,
    required this.title,
    required this.connected,
    required this.detail,
    required this.busy,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(connected ? (detail ?? 'Connected') : 'Not added'),
      trailing: connected
          ? Icon(AppIcons.success, color: scheme.primary, semanticLabel: 'Connected')
          : OutlinedButton(onPressed: busy ? null : onAdd, child: const Text('Add')),
    );
  }
}

/// Attach an email + password to the signed-in account.
class _AddPasswordSheet extends StatefulWidget {
  final String initialEmail;
  const _AddPasswordSheet({required this.initialEmail});

  @override
  State<_AddPasswordSheet> createState() => _AddPasswordSheetState();
}

class _AddPasswordSheetState extends State<_AddPasswordSheet> {
  late final TextEditingController _email = TextEditingController(text: widget.initialEmail);
  final _password = TextEditingController();
  String? _passwordError;
  String? _failure;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final passwordError = AuthService.validatePassword(_password.text);
    setState(() {
      _passwordError = passwordError;
      _failure = null;
    });
    if (passwordError != null || _email.text.trim().isEmpty) return;
    final auth = context.read<AuthProvider>();
    final ok = await auth.linkEmailPassword(email: _email.text.trim(), password: _password.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      final f = auth.failure;
      setState(() => _failure = f == null ? null : '${f.title}. ${f.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AuthProvider>().isLoading;
    return _SheetFrame(
      title: 'Add email and password',
      children: [
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.newPassword],
          decoration: InputDecoration(labelText: 'Choose a password', errorText: _passwordError),
        ),
        if (_failure != null) _FailureText(_failure!),
        const SizedBox(height: 16),
        FilledButton(onPressed: busy ? null : _submit, child: Text(busy ? 'Adding…' : 'Add')),
      ],
    );
  }
}

/// Attach a verified phone number to the signed-in account. Uses the same OTP
/// machinery as phone sign-in, with `forLinking: true` so Android's instant
/// verification links the credential instead of signing in with it.
class _AddPhoneSheet extends StatefulWidget {
  const _AddPhoneSheet();

  @override
  State<_AddPhoneSheet> createState() => _AddPhoneSheetState();
}

class _AddPhoneSheetState extends State<_AddPhoneSheet> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  String? _phoneError;
  String? _failure;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  String _failureText(AuthFailure? f) => f == null ? 'Please try again.' : '${f.title}. ${f.message}';

  Future<void> _sendCode() async {
    final national = KenyanPhone.nationalDigitsFrom(_phone.text);
    final error = KenyanPhone.submitError(national);
    setState(() {
      _phoneError = error;
      _failure = null;
    });
    if (error != null) return;
    final e164 = KenyanPhone.toE164(_phone.text);
    if (e164 == null) return;

    final auth = context.read<AuthProvider>();
    final ok = await auth.sendOtp(e164, forLinking: true);
    if (!mounted) return;
    if (!ok) {
      setState(() => _failure = _failureText(auth.failure));
      return;
    }
    if (auth.autoVerified) {
      // The SMS was read on this device and the number is already linked.
      auth.clearPhoneState();
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _codeSent = true);
  }

  Future<void> _verify() async {
    final auth = context.read<AuthProvider>();
    final ok = await auth.linkPhone(_code.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _failure = _failureText(auth.failure));
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AuthProvider>().isLoading;
    return _SheetFrame(
      title: 'Add a phone number',
      children: [
        TextField(
          controller: _phone,
          enabled: !_codeSent,
          keyboardType: TextInputType.phone,
          inputFormatters: const [KenyanPhoneInputFormatter()],
          decoration: InputDecoration(
            labelText: 'Phone number',
            prefixText: '${KenyanPhone.dialCode} ',
            errorText: _phoneError,
          ),
        ),
        if (_codeSent) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            decoration: const InputDecoration(labelText: 'Code from the SMS'),
          ),
        ],
        if (_failure != null) _FailureText(_failure!),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy ? null : (_codeSent ? _verify : _sendCode),
          child: Text(busy ? 'Working…' : (_codeSent ? 'Verify and add' : 'Send code')),
        ),
      ],
    );
  }
}

class _SheetFrame extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SheetFrame({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}

class _FailureText extends StatelessWidget {
  final String text;
  const _FailureText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }
}
