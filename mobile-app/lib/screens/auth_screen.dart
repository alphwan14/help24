import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/auth_error_mapper.dart';
import '../utils/kenyan_phone.dart';
import '../utils/name_validator.dart';
import '../widgets/auth/otp_input.dart';
import '../widgets/auth/phone_number_field.dart';
import '../widgets/google_logo.dart';

/// Steps in the onboarding flow.
///
/// WHY `emailIdentify` EXISTS — THE SIGN-IN / SIGN-UP CONFUSION
/// -----------------------------------------------------------
/// The previous screen opened on a "Sign In | Sign Up" segmented toggle and
/// repeated the same choice as a link underneath it. That asks the user a
/// question they cannot reliably answer: *"do I already have a Help24
/// account?"* — six months after signing up, on a shared phone, having also
/// once used the Google button, most people genuinely do not know. Choosing
/// wrong produced a dead end in both directions: "No account found with this
/// email. Sign up instead?" (a question with no button) or "This email is
/// already registered. Try signing in instead." (retype everything).
///
/// So Help24 no longer asks. The user types their email ONCE, and the app
/// works out which door they are standing at — the pattern Google, Stripe,
/// Slack and Notion all converged on. The toggle is gone entirely.
enum _AuthStep {
  welcome,
  phoneInput,
  otpVerify,
  emailIdentify,
  emailPassword,
  emailCreate,
  profileSetup,
}

/// Production auth: Welcome → Phone/Email → OTP or password → profile setup.
class AuthScreen extends StatefulWidget {
  final String? action;
  final bool isModal;
  final VoidCallback? onSuccess;

  const AuthScreen({
    super.key,
    this.action,
    this.isModal = false,
    this.onSuccess,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _AuthStep _step = _AuthStep.welcome;

  /// The email carried between steps, so switching between "sign in" and
  /// "create account" NEVER makes the user retype it. This single field is
  /// most of what stops the flow dead-ending.
  String _email = '';

  /// Ensures the auth route/modal is dismissed EXACTLY once. authStateChanges
  /// can fire several times around a successful login (credential + token
  /// refresh + profile load); without this guard a second _onSuccess() could
  /// pop the wrong route or throw.
  bool _dismissed = false;

  void _goTo(_AuthStep step) {
    if (!mounted) return;
    context.read<AuthProvider>().clearError();
    setState(() => _step = step);
  }

  void _onSuccess() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    if (widget.onSuccess != null) {
      widget.onSuccess!.call();
    } else if (Navigator.canPop(context)) {
      Navigator.of(context).pop(true);
    }
  }

  /// Where "back" goes from each step. Modelled explicitly rather than
  /// popping a stack, because several steps can be reached from more than one
  /// predecessor (create-account is reachable from identify AND from password).
  _AuthStep? get _previousStep {
    switch (_step) {
      case _AuthStep.welcome:
        return null;
      case _AuthStep.phoneInput:
      case _AuthStep.emailIdentify:
        return _AuthStep.welcome;
      case _AuthStep.otpVerify:
        return _AuthStep.phoneInput;
      case _AuthStep.emailPassword:
      case _AuthStep.emailCreate:
        return _AuthStep.emailIdentify;
      case _AuthStep.profileSetup:
        // Deliberately no way back: the account already exists at this point,
        // and reversing would strand a nameless account.
        return null;
    }
  }

  void _back() {
    final previous = _previousStep;
    if (previous == null) return;
    if (_step == _AuthStep.otpVerify || _step == _AuthStep.phoneInput) {
      context.read<AuthProvider>().clearPhoneState();
    }
    _goTo(previous);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor:
            isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(isDark),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  physics: const ClampingScrollPhysics(),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.04, 0),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                        )),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _buildStep(isDark),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isDark) {
    final canGoBack = _previousStep != null;
    final showClose = widget.isModal;
    if (!canGoBack && !showClose) return const SizedBox(height: 8);

    final iconColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          if (canGoBack)
            IconButton(
              onPressed: _back,
              tooltip: 'Back',
              icon: Icon(Icons.arrow_back_ios_new, size: 20, color: iconColor),
            ),
          const Spacer(),
          if (showClose)
            IconButton(
              onPressed: () => Navigator.of(context).pop(false),
              tooltip: 'Close',
              icon: Icon(Icons.close, color: iconColor),
            ),
        ],
      ),
    );
  }

  Widget _buildStep(bool isDark) {
    switch (_step) {
      case _AuthStep.welcome:
        return _WelcomeStep(
          action: widget.action,
          onPhone: () => _goTo(_AuthStep.phoneInput),
          onEmail: () => _goTo(_AuthStep.emailIdentify),
          onGoogleSuccess: _afterCredential,
        );

      case _AuthStep.phoneInput:
        return _PhoneInputStep(onSent: () => _goTo(_AuthStep.otpVerify));

      case _AuthStep.otpVerify:
        return _OtpVerifyStep(
          onSuccess: _afterCredential,
          onRestart: () => _goTo(_AuthStep.phoneInput),
        );

      case _AuthStep.emailIdentify:
        return _EmailIdentifyStep(
          initialEmail: _email,
          onContinue: (email, status) {
            setState(() => _email = email);
            _goTo(status == AccountStatus.none
                ? _AuthStep.emailCreate
                : _AuthStep.emailPassword);
          },
        );

      case _AuthStep.emailPassword:
        return _EmailPasswordStep(
          email: _email,
          onSuccess: _afterCredential,
          onCreateAccount: () => _goTo(_AuthStep.emailCreate),
          onChangeEmail: () => _goTo(_AuthStep.emailIdentify),
        );

      case _AuthStep.emailCreate:
        return _EmailCreateStep(
          email: _email,
          onSuccess: _afterCredential,
          onSignInInstead: () => _goTo(_AuthStep.emailPassword),
          onChangeEmail: () => _goTo(_AuthStep.emailIdentify),
        );

      case _AuthStep.profileSetup:
        return _ProfileSetupStep(onDone: _onSuccess);
    }
  }

  /// Single landing point after ANY successful credential (phone, email,
  /// Google): decide whether the account still needs a name before letting it
  /// loose in the marketplace, where the name is attached to every job and
  /// review.
  void _afterCredential() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (auth.needsProfileSetup) {
      _goTo(_AuthStep.profileSetup);
    } else {
      _onSuccess();
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Welcome
// ═══════════════════════════════════════════════════════════════════════════

class _WelcomeStep extends StatefulWidget {
  final String? action;
  final VoidCallback onPhone;
  final VoidCallback onEmail;
  final VoidCallback onGoogleSuccess;

  const _WelcomeStep({
    this.action,
    required this.onPhone,
    required this.onEmail,
    required this.onGoogleSuccess,
  });

  @override
  State<_WelcomeStep> createState() => _WelcomeStepState();
}

class _WelcomeStepState extends State<_WelcomeStep> {
  bool _googleLoading = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _googleLoading = true);
    final ok = await context.read<AuthProvider>().signInWithGoogle();
    if (!mounted) return;
    setState(() => _googleLoading = false);
    if (ok) widget.onGoogleSuccess();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final subColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final auth = context.watch<AuthProvider>();

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset(
                'assets/help24_icon.png',
                width: 80,
                height: 80,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Help24',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  color: textColor,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            'Find help. Offer services.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: subColor),
          ),
          if (widget.action != null) ...[
            const SizedBox(height: 14),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Continue to ${widget.action}',
                  style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 36),

          if (auth.failure != null) ...[
            _FailureCard(failure: auth.failure!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],

          // One verb — "Continue" — on every route in. The user is not asked
          // to declare whether they are new here; that is the app's job.
          _AuthButton(
            label: 'Continue with phone',
            icon: Iconsax.call,
            onPressed: widget.onPhone,
            primary: true,
          ),
          const SizedBox(height: 12),
          _AuthButton(
            label: 'Continue with email',
            icon: Iconsax.sms,
            onPressed: widget.onEmail,
            primary: false,
          ),
          const SizedBox(height: 20),
          const _OrDivider(),
          const SizedBox(height: 16),
          _GoogleSignInButton(
            loading: _googleLoading,
            onPressed: _signInWithGoogle,
          ),
          const SizedBox(height: 24),
          const _LegalFootnote(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Phone
// ═══════════════════════════════════════════════════════════════════════════

class _PhoneInputStep extends StatefulWidget {
  final VoidCallback onSent;

  const _PhoneInputStep({required this.onSent});

  @override
  State<_PhoneInputStep> createState() => _PhoneInputStepState();
}

class _PhoneInputStepState extends State<_PhoneInputStep> {
  final _controller = TextEditingController();
  final _fieldKey = GlobalKey<State<PhoneNumberField>>();
  String _national = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isComplete => KenyanPhone.isValidNational(_national);

  Future<void> _send() async {
    final auth = context.read<AuthProvider>();
    final error = KenyanPhone.submitError(_national);
    if (error != null) {
      // Tell the FIELD, not a banner: the mistake is in the field, so that is
      // where the correction belongs.
      (_fieldKey.currentState as dynamic)?.markSubmitted();
      auth.clearError();
      return;
    }
    final e164 = KenyanPhone.toE164(_national);
    if (e164 == null) return;

    FocusScope.of(context).unfocus();
    final ok = await auth.sendOtp(e164);
    if (ok && mounted) widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeading(
            title: "What's your number?",
            subtitle: "We'll text you a 6-digit code to confirm it's you.",
            isDark: isDark,
          ),
          const SizedBox(height: 28),
          if (auth.failure != null) ...[
            _FailureCard(failure: auth.failure!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],
          PhoneNumberField(
            key: _fieldKey,
            controller: _controller,
            onChanged: (national) => setState(() => _national = national),
            onSubmitted: (_) => _send(),
          ),
          const SizedBox(height: 28),
          _PrimaryButton(
            label: 'Send code',
            loading: auth.isLoading,
            // Disabled until the number is actually dialable: a button that
            // can only fail should not be pressable.
            onPressed: _isComplete ? _send : null,
          ),
          const SizedBox(height: 16),
          _SmsCostNote(isDark: isDark),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// OTP
// ═══════════════════════════════════════════════════════════════════════════

class _OtpVerifyStep extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onRestart;

  const _OtpVerifyStep({required this.onSuccess, required this.onRestart});

  @override
  State<_OtpVerifyStep> createState() => _OtpVerifyStepState();
}

class _OtpVerifyStepState extends State<_OtpVerifyStep> {
  final _otpKey = GlobalKey<OtpInputState>();

  /// Resend backs off: 30s, then 60s, then 120s. A fixed 30s window lets a
  /// user with no signal burn through the SMS quota in a couple of minutes and
  /// hit a provider-level block that lasts far longer.
  static const List<int> _backoffSeconds = [30, 60, 120];
  int _resendCount = 0;
  int _remaining = 0;
  Timer? _timer;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _startCountdown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      // Android instant verification may have already signed the user in
      // before this screen even painted.
      if (auth.isLoggedIn) {
        auth.clearPhoneState();
        widget.onSuccess();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    final seconds =
        _backoffSeconds[_resendCount.clamp(0, _backoffSeconds.length - 1)];
    _timer?.cancel();
    setState(() => _remaining = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _timer?.cancel();
        setState(() => _remaining = 0);
        return;
      }
      setState(() => _remaining--);
    });
  }

  Future<void> _verify(String code) async {
    final auth = context.read<AuthProvider>();
    setState(() => _hasError = false);
    final ok = await auth.verifyOtp(code);
    if (!mounted) return;
    if (ok) {
      widget.onSuccess();
      return;
    }
    // Wrong code: shake, clear, and hand focus straight back so the next
    // attempt costs one tap less than it used to.
    setState(() => _hasError = true);
    _otpKey.currentState?.clear();
    if (auth.failure?.recovery == AuthRecovery.restartPhone) {
      widget.onRestart();
    }
  }

  Future<void> _resend() async {
    if (_remaining > 0) return;
    final auth = context.read<AuthProvider>();
    setState(() => _hasError = false);
    _otpKey.currentState?.clear();
    final ok = await auth.resendOtp();
    if (!mounted) return;
    if (ok) {
      setState(() => _resendCount++);
      _startCountdown();
    } else if (auth.failure?.recovery == AuthRecovery.restartPhone) {
      widget.onRestart();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final phone = auth.pendingPhoneNumber ?? '';
    final display =
        phone.isEmpty ? 'your phone' : KenyanPhone.formatE164ForDisplay(phone);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeading(
            title: 'Enter your code',
            subtitle: 'We sent a 6-digit code to $display.',
            isDark: isDark,
          ),
          const SizedBox(height: 28),
          if (auth.failure != null) ...[
            _FailureCard(
              failure: auth.failure!,
              onDismiss: auth.clearError,
              onAction: auth.failure!.recovery == AuthRecovery.resendCode
                  ? () {
                      auth.clearError();
                      setState(() => _remaining = 0);
                      _resend();
                    }
                  : auth.failure!.recovery == AuthRecovery.restartPhone
                      ? widget.onRestart
                      : null,
            ),
            const SizedBox(height: 20),
          ],
          OtpInput(
            key: _otpKey,
            enabled: !auth.isLoading,
            hasError: _hasError,
            // Auto-submits the moment the sixth digit lands — no button to
            // hunt for, which is also what makes SMS autofill feel instant.
            onCompleted: _verify,
            onChanged: (_) {
              if (_hasError) setState(() => _hasError = false);
            },
          ),
          const SizedBox(height: 24),
          if (auth.isLoading)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            )
          else
            _ResendRow(
              remaining: _remaining,
              onResend: _resend,
              isDark: isDark,
            ),
          const SizedBox(height: 20),
          Center(
            child: TextButton(
              onPressed: widget.onRestart,
              child: const Text('Use a different number'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ResendRow extends StatelessWidget {
  final int remaining;
  final VoidCallback onResend;
  final bool isDark;

  const _ResendRow({
    required this.remaining,
    required this.onResend,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final subColor =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    if (remaining > 0) {
      final label = remaining >= 60
          ? '${(remaining / 60).ceil()} min'
          : '${remaining}s';
      return Center(
        child: Text(
          'Didn’t get it? You can ask for a new code in $label',
          textAlign: TextAlign.center,
          style: TextStyle(color: subColor, fontSize: 14),
        ),
      );
    }
    return Center(
      child: TextButton.icon(
        onPressed: onResend,
        icon: const Icon(Iconsax.refresh, size: 18),
        label: const Text('Send a new code'),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Email — step 1: identify
// ═══════════════════════════════════════════════════════════════════════════

/// Asks for the email and nothing else, then decides which door to open.
class _EmailIdentifyStep extends StatefulWidget {
  final String initialEmail;
  final void Function(String email, AccountStatus status) onContinue;

  const _EmailIdentifyStep({
    required this.initialEmail,
    required this.onContinue,
  });

  @override
  State<_EmailIdentifyStep> createState() => _EmailIdentifyStepState();
}

class _EmailIdentifyStepState extends State<_EmailIdentifyStep> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialEmail);
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final email = _controller.text.trim();
    final auth = context.read<AuthProvider>();

    if (!AuthService.isValidEmail(email)) {
      auth.setFailure(const AuthFailure(
        title: 'Check your email',
        message: "That email address doesn't look right.",
      ));
      return;
    }

    FocusScope.of(context).unfocus();
    auth.clearError();
    setState(() => _checking = true);
    final status = await auth.lookupAccount(email);
    if (!mounted) return;
    setState(() => _checking = false);

    // `unknown` (enumeration protection on) routes to the password step: it is
    // the correct guess for a returning user, and if it turns out to be wrong
    // the password step offers "Create account" with the email carried over.
    widget.onContinue(email, status);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeading(
            title: "What's your email?",
            subtitle:
                "We'll check whether you already have a Help24 account and take "
                'you to the right place.',
            isDark: isDark,
          ),
          const SizedBox(height: 28),
          if (auth.failure != null) ...[
            _FailureCard(failure: auth.failure!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],
          _AuthField(
            controller: _controller,
            hint: 'you@example.com',
            icon: Iconsax.sms,
            keyboardType: TextInputType.emailAddress,
            action: TextInputAction.done,
            autofocus: true,
            autofillHints: const [AutofillHints.email],
            onSubmitted: (_) => _continue(),
          ),
          const SizedBox(height: 24),
          _PrimaryButton(
            label: 'Continue',
            loading: _checking,
            onPressed: _continue,
          ),
          const SizedBox(height: 24),
          const _LegalFootnote(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Email — step 2a: password (returning user)
// ═══════════════════════════════════════════════════════════════════════════

class _EmailPasswordStep extends StatefulWidget {
  final String email;
  final VoidCallback onSuccess;
  final VoidCallback onCreateAccount;
  final VoidCallback onChangeEmail;

  const _EmailPasswordStep({
    required this.email,
    required this.onSuccess,
    required this.onCreateAccount,
    required this.onChangeEmail,
  });

  @override
  State<_EmailPasswordStep> createState() => _EmailPasswordStepState();
}

class _EmailPasswordStepState extends State<_EmailPasswordStep> {
  final _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final auth = context.read<AuthProvider>();
    if (_password.text.isEmpty) {
      auth.setFailure(const AuthFailure(
        title: 'Enter your password',
        message: 'Type the password for this account to continue.',
      ));
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await auth.signIn(email: widget.email, password: _password.text);
    if (ok && mounted) widget.onSuccess();
  }

  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ForgotPasswordSheet(
        initialEmail: widget.email,
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final failure = auth.failure;

    // The two ways a sign-in attempt can tell us we guessed the wrong door.
    final offerCreate = failure?.recovery == AuthRecovery.createAccount;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeading(
            title: 'Welcome back',
            subtitle: 'Enter your password to continue.',
            isDark: isDark,
          ),
          const SizedBox(height: 16),
          _EmailChip(email: widget.email, onChange: widget.onChangeEmail),
          const SizedBox(height: 20),
          if (failure != null) ...[
            _FailureCard(
              failure: failure,
              onDismiss: auth.clearError,
              onAction: offerCreate
                  ? widget.onCreateAccount
                  : failure.recovery == AuthRecovery.resetPassword
                      ? _showForgotPassword
                      : null,
            ),
            const SizedBox(height: 16),
          ],
          _AuthField(
            controller: _password,
            hint: 'Password',
            icon: Iconsax.lock,
            obscure: _obscure,
            autofocus: true,
            action: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _signIn(),
            suffixIcon: _ObscureToggle(
              obscured: _obscure,
              isDark: isDark,
              onTap: () => setState(() => _obscure = !_obscure),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _showForgotPassword,
              child: const Text('Forgot password?'),
            ),
          ),
          const SizedBox(height: 8),
          _PrimaryButton(
            label: 'Sign in',
            loading: auth.isLoading,
            onPressed: _signIn,
          ),
          const SizedBox(height: 20),
          // Always present, not only after a failure: a user who knows they
          // are new should never have to fail first to find the way forward.
          _InlineSwitch(
            question: 'Not your account?',
            actionLabel: 'Create a new one',
            onTap: widget.onCreateAccount,
            isDark: isDark,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Email — step 2b: create account (new user)
// ═══════════════════════════════════════════════════════════════════════════

class _EmailCreateStep extends StatefulWidget {
  final String email;
  final VoidCallback onSuccess;
  final VoidCallback onSignInInstead;
  final VoidCallback onChangeEmail;

  const _EmailCreateStep({
    required this.email,
    required this.onSuccess,
    required this.onSignInInstead,
    required this.onChangeEmail,
  });

  @override
  State<_EmailCreateStep> createState() => _EmailCreateStepState();
}

class _EmailCreateStepState extends State<_EmailCreateStep> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String _passwordValue = '';

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final auth = context.read<AuthProvider>();

    // Same name rules as the rest of the product (migration 087 makes the
    // 30-day change cooldown authoritative), applied at the point of entry so
    // a user is never allowed to set a name they would immediately be stuck
    // with and unable to correct.
    final nameCheck = NameValidator.check(_name.text);
    if (!nameCheck.ok) {
      auth.setFailure(AuthFailure(
        title: 'Check your name',
        message: nameCheck.error!,
      ));
      return;
    }

    final passwordError = AuthService.validatePassword(_password.text);
    if (passwordError != null) {
      auth.setFailure(AuthFailure(
        title: 'Choose a stronger password',
        message: passwordError,
      ));
      return;
    }

    FocusScope.of(context).unfocus();
    final ok = await auth.signUp(
      email: widget.email,
      password: _password.text,
      name: nameCheck.normalized,
    );
    if (ok && mounted) widget.onSuccess();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final failure = auth.failure;
    final offerSignIn = failure?.recovery == AuthRecovery.signIn;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeading(
            title: 'Create your account',
            subtitle: 'Two details and you’re in.',
            isDark: isDark,
          ),
          const SizedBox(height: 16),
          _EmailChip(email: widget.email, onChange: widget.onChangeEmail),
          const SizedBox(height: 20),
          if (failure != null) ...[
            _FailureCard(
              failure: failure,
              onDismiss: auth.clearError,
              // "Already registered" becomes a BUTTON that carries the email
              // to the password step — never a sentence telling the user to go
              // back and start again.
              onAction: offerSignIn ? widget.onSignInInstead : null,
            ),
            const SizedBox(height: 16),
          ],
          _AuthField(
            controller: _name,
            hint: 'First and last name',
            icon: Iconsax.user,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            action: TextInputAction.next,
            autofillHints: const [AutofillHints.name],
          ),
          const SizedBox(height: 10),
          _AuthField(
            controller: _password,
            hint: 'Create a password',
            icon: Iconsax.lock,
            obscure: _obscure,
            action: TextInputAction.done,
            autofillHints: const [AutofillHints.newPassword],
            onChanged: (v) => setState(() => _passwordValue = v),
            onSubmitted: (_) => _create(),
            suffixIcon: _ObscureToggle(
              obscured: _obscure,
              isDark: isDark,
              onTap: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 10),
          _PasswordStrengthBar(password: _passwordValue, isDark: isDark),
          const SizedBox(height: 20),
          _PrimaryButton(
            label: 'Create account',
            loading: auth.isLoading,
            onPressed: _create,
          ),
          const SizedBox(height: 20),
          _InlineSwitch(
            question: 'Already have an account?',
            actionLabel: 'Sign in',
            onTap: widget.onSignInInstead,
            isDark: isDark,
          ),
          const SizedBox(height: 16),
          const _LegalFootnote(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Length-first strength feedback. Deliberately not a scold: it explains what
/// would make the password better rather than blocking on character classes,
/// which is what pushes people towards `Password1!` and a sticky note.
class _PasswordStrengthBar extends StatelessWidget {
  final String password;
  final bool isDark;

  const _PasswordStrengthBar({required this.password, required this.isDark});

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) {
      return Text(
        'Use at least ${AuthService.minPasswordLength} characters.',
        style: TextStyle(
          fontSize: 12.5,
          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
        ),
      );
    }

    final score = AuthService.passwordStrength(password);
    const labels = ['Too short', 'Okay', 'Good', 'Strong'];
    const colors = [
      AppTheme.errorRed,
      AppTheme.warningOrange,
      AppTheme.secondaryAccent,
      AppTheme.successGreen,
    ];

    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 4,
              decoration: BoxDecoration(
                color: i < score
                    ? colors[score]
                    : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < 2) const SizedBox(width: 6),
        ],
        const SizedBox(width: 12),
        SizedBox(
          width: 66,
          child: Text(
            labels[score],
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: colors[score],
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Profile setup
// ═══════════════════════════════════════════════════════════════════════════

class _ProfileSetupStep extends StatefulWidget {
  final VoidCallback onDone;

  const _ProfileSetupStep({required this.onDone});

  @override
  State<_ProfileSetupStep> createState() => _ProfileSetupStepState();
}

class _ProfileSetupStepState extends State<_ProfileSetupStep> {
  final _nameController = TextEditingController();
  XFile? _pickedFile;
  bool _uploading = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        imageQuality: 85,
      );
      if (xFile != null && mounted) setState(() => _pickedFile = xFile);
    } catch (e) {
      debugPrint('[AUTH] image pick cancelled or failed: ${e.runtimeType}');
    }
  }

  Future<void> _submit() async {
    final auth = context.read<AuthProvider>();
    final check = NameValidator.check(_nameController.text);
    if (!check.ok) {
      auth.setFailure(AuthFailure(
        title: 'Check your name',
        message: check.error!,
      ));
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _uploading = true);
    String? photoUrl;
    if (_pickedFile != null) {
      try {
        photoUrl = await StorageService.uploadProfileImage(
          _pickedFile!,
          auth.currentUserId ?? '',
        );
      } catch (e) {
        // A failed avatar upload must not block account setup — the photo is
        // optional and can be added later from the profile screen.
        debugPrint('[AUTH] avatar upload failed: ${e.runtimeType}');
      }
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    final ok = await auth.updateProfile(
      name: check.normalized,
      photoUrl: photoUrl,
    );
    if (ok && mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepHeading(
            title: 'What should we call you?',
            subtitle:
                'Your name appears on your posts, your messages and your '
                'reviews, so use the name people will recognise.',
            isDark: isDark,
          ),
          const SizedBox(height: 28),
          if (auth.failure != null) ...[
            _FailureCard(failure: auth.failure!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],
          Center(
            child: GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                  borderRadius: BorderRadius.circular(50),
                  border: Border.all(
                    color: _pickedFile != null
                        ? AppTheme.successGreen
                        : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                    width: 2,
                  ),
                ),
                child: _pickedFile != null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Iconsax.gallery_tick,
                              size: 36, color: AppTheme.successGreen),
                          SizedBox(height: 4),
                          Text(
                            'Photo added',
                            style: TextStyle(
                                fontSize: 11, color: AppTheme.successGreen),
                          ),
                        ],
                      )
                    : Icon(
                        Iconsax.camera,
                        size: 36,
                        color: isDark
                            ? AppTheme.darkTextTertiary
                            : AppTheme.lightTextTertiary,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              'Add a photo (optional)',
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? AppTheme.darkTextTertiary
                    : AppTheme.lightTextTertiary,
              ),
            ),
          ),
          const SizedBox(height: 24),
          _AuthField(
            controller: _nameController,
            hint: 'First and last name',
            icon: Iconsax.user,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            action: TextInputAction.done,
            autofillHints: const [AutofillHints.name],
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 10),
          Text(
            'You can change this once every 30 days.',
            style: TextStyle(
              fontSize: 12.5,
              color:
                  isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ),
          const SizedBox(height: 28),
          _PrimaryButton(
            label: 'Continue',
            loading: auth.isLoading || _uploading,
            onPressed: _submit,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Forgot password
// ═══════════════════════════════════════════════════════════════════════════

class _ForgotPasswordSheet extends StatefulWidget {
  final String initialEmail;
  final VoidCallback onClose;

  const _ForgotPasswordSheet({
    required this.initialEmail,
    required this.onClose,
  });

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail);
  bool _sent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final auth = context.read<AuthProvider>();
    final email = _emailController.text.trim();
    if (!AuthService.isValidEmail(email)) {
      auth.setFailure(const AuthFailure(
        title: 'Check your email',
        message: "That email address doesn't look right.",
      ));
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await auth.sendPasswordResetEmail(email);
    if (ok && mounted) setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (_sent) ...[
            const Icon(Icons.mark_email_read_outlined,
                color: AppTheme.successGreen, size: 52),
            const SizedBox(height: 16),
            Text(
              'Check your email',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            // Phrased so it is true whether or not the address is registered —
            // a reset form that confirms which emails exist is an account-
            // harvesting tool.
            Text(
              'If ${_emailController.text.trim()} has a Help24 account, a reset '
              'link is on its way. It expires in one hour.',
              style: TextStyle(color: textSecondary, height: 1.45),
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing after a few minutes? Check your spam or promotions folder.',
              style: TextStyle(color: textSecondary, fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 24),
            _PrimaryButton(
                label: 'Done', loading: false, onPressed: widget.onClose),
          ] else ...[
            Text(
              'Reset your password',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              "Enter your email and we'll send you a link to set a new password.",
              style: TextStyle(color: textSecondary, height: 1.45),
            ),
            const SizedBox(height: 20),
            if (auth.failure != null) ...[
              _FailureCard(failure: auth.failure!, onDismiss: auth.clearError),
              const SizedBox(height: 16),
            ],
            _AuthField(
              controller: _emailController,
              hint: 'you@example.com',
              icon: Iconsax.sms,
              keyboardType: TextInputType.emailAddress,
              action: TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              onSubmitted: (_) => _send(),
            ),
            const SizedBox(height: 20),
            _PrimaryButton(
              label: 'Send reset link',
              loading: auth.isLoading,
              onPressed: _send,
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared UI
// ═══════════════════════════════════════════════════════════════════════════

class _StepHeading extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isDark;

  const _StepHeading({
    required this.title,
    required this.subtitle,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color:
                    isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 15,
            height: 1.45,
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
          ),
        ),
      ],
    );
  }
}

/// Shows the email the user is working with and lets them change it in one
/// tap. Without this, a typo in step 1 means backing out of the whole flow.
class _EmailChip extends StatelessWidget {
  final String email;
  final VoidCallback onChange;

  const _EmailChip({required this.email, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : const Color(0xFFF1F3F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Iconsax.sms,
            size: 17,
            color:
                isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              email,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w500,
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Change', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// A failure, rendered with its recovery action as a real button.
///
/// This widget is why the flow has no dead ends: every [AuthFailure] that
/// knows what the user should do next renders that as something tappable,
/// carrying the email/phone already entered.
class _FailureCard extends StatelessWidget {
  final AuthFailure failure;
  final VoidCallback onDismiss;
  final VoidCallback? onAction;

  const _FailureCard({
    required this.failure,
    required this.onDismiss,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final actionLabel = failure.actionLabel;
    final showAction = onAction != null && actionLabel != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppTheme.errorRed.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.errorRed.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Iconsax.info_circle,
                    color: AppTheme.errorRed, size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      failure.title,
                      style: const TextStyle(
                        color: AppTheme.errorRed,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      failure.message,
                      style: const TextStyle(
                        color: AppTheme.errorRed,
                        fontSize: 13.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 17, color: AppTheme.errorRed),
                onPressed: onDismiss,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Dismiss',
              ),
            ],
          ),
          if (showAction) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.errorRed,
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  actionLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineSwitch extends StatelessWidget {
  final String question;
  final String actionLabel;
  final VoidCallback onTap;
  final bool isDark;

  const _InlineSwitch({
    required this.question,
    required this.actionLabel,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          question,
          style: TextStyle(
            fontSize: 13.5,
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: onTap,
          child: Text(
            actionLabel,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppTheme.primaryAccent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _SmsCostNote extends StatelessWidget {
  final bool isDark;

  const _SmsCostNote({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Iconsax.shield_tick,
          size: 15,
          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Your number is only used to sign you in and is never shown on your '
            'posts.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: isDark
                  ? AppTheme.darkTextTertiary
                  : AppTheme.lightTextTertiary,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegalFootnote extends StatelessWidget {
  const _LegalFootnote();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      'By continuing you agree to the Help24 Terms of Service and Privacy Policy.',
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        height: 1.45,
        color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
      ),
    );
  }
}

class _ObscureToggle extends StatelessWidget {
  final bool obscured;
  final bool isDark;
  final VoidCallback onTap;

  const _ObscureToggle({
    required this.obscured,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: obscured ? 'Show password' : 'Hide password',
      icon: Icon(
        obscured ? Iconsax.eye_slash : Iconsax.eye,
        size: 19,
        color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
      ),
    );
  }
}

class _AuthButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;

  const _AuthButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: primary
          ? AppTheme.primaryAccent
          : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 17),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: primary
                ? null
                : Border.all(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 21,
                color: primary
                    ? Colors.white
                    : (isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: primary
                      ? Colors.white
                      : (isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool obscure;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? action;
  final TextCapitalization textCapitalization;
  final Widget? suffixIcon;
  final List<String>? autofillHints;
  final void Function(String)? onSubmitted;
  final void Function(String)? onChanged;

  const _AuthField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.autofocus = false,
    this.keyboardType,
    this.action,
    this.textCapitalization = TextCapitalization.none,
    this.suffixIcon,
    this.autofillHints,
    this.onSubmitted,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor =
        isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: autofocus,
      keyboardType: keyboardType,
      textInputAction: action ?? TextInputAction.next,
      textCapitalization: textCapitalization,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: TextStyle(
        fontSize: 15.5,
        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: iconColor, fontSize: 15.5),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 14, right: 10),
          child: Icon(icon, size: 19, color: iconColor),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 44, minHeight: 48),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        counterText: '',
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppTheme.primaryAccent, width: 1.6),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final bool loading;

  /// Null disables the button — used where pressing it could only fail.
  final VoidCallback? onPressed;

  const _PrimaryButton({
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryAccent,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              AppTheme.primaryAccent.withValues(alpha: 0.35),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.75),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2.2, color: Colors.white),
              )
            : Text(
                label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lineColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textColor =
        isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Row(
      children: [
        Expanded(child: Divider(color: lineColor, thickness: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'OR',
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
        ),
        Expanded(child: Divider(color: lineColor, thickness: 1)),
      ],
    );
  }
}

/// "Continue with Google" per Google's sign-in branding guidance: the official
/// G mark (never redrawn), a white surface in light mode / the dark-scheme
/// surface in dark mode, and balanced 12dp icon-to-label spacing.
///
/// This is the ONE place a vendor name legitimately appears in the UI, and it
/// is required rather than leaked: the button identifies WHICH account the
/// user is about to sign in with, and Google's brand guidelines mandate both
/// the mark and the wording. Hiding it would make the button dishonest.
class _GoogleSignInButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;

  const _GoogleSignInButton({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF131314) : Colors.white;
    final border = isDark ? const Color(0xFF3C4043) : const Color(0xFFDADCE0);
    final label = isDark ? Colors.white : const Color(0xFF1F1F1F);

    return SizedBox(
      height: 52,
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: loading ? null : onPressed,
          borderRadius: BorderRadius.circular(12),
          splashColor: Colors.black.withValues(alpha: 0.04),
          highlightColor: Colors.black.withValues(alpha: 0.02),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border),
            ),
            alignment: Alignment.center,
            child: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const GoogleLogo(size: 20),
                      const SizedBox(width: 12),
                      Text(
                        'Continue with Google',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                          color: label,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
