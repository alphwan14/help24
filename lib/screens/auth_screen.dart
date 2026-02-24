import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';
import '../services/storage_service.dart';

enum _AuthStep { welcome, phoneInput, otpVerify, emailAuth, profileSetup }

/// Production-level auth: Welcome → Phone/Email → OTP or Email form → Profile setup (if new).
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

  void _goTo(_AuthStep step) => setState(() => _step = step);

  void _onSuccess() {
    if (!mounted) return;
    widget.onSuccess?.call();
    // If caller did not handle navigation, pop so user returns to app (no back button)
    if (mounted && widget.onSuccess == null && Navigator.canPop(context)) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
        body: SafeArea(
          child: Column(
            children: [
              if (_step != _AuthStep.welcome)
                _buildBackBar(context, isDark)
              else if (widget.isModal)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(Icons.close, color: Theme.of(context).brightness == Brightness.dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildStep(isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBackBar(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              if (_step == _AuthStep.phoneInput || _step == _AuthStep.otpVerify) {
                context.read<AuthProvider>().clearPhoneState();
              }
              switch (_step) {
                case _AuthStep.phoneInput:
                case _AuthStep.emailAuth:
                case _AuthStep.profileSetup:
                  _goTo(_AuthStep.welcome);
                  break;
                case _AuthStep.otpVerify:
                  _goTo(_AuthStep.phoneInput);
                  break;
                case _AuthStep.welcome:
                  break;
              }
            },
            icon: Icon(Icons.arrow_back_ios_new, size: 20, color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
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
          onEmail: () => _goTo(_AuthStep.emailAuth),
        );
      case _AuthStep.phoneInput:
        return _PhoneInputStep(
          onSent: () => _goTo(_AuthStep.otpVerify),
          onBack: () => _goTo(_AuthStep.welcome),
        );
      case _AuthStep.otpVerify:
        return _OtpVerifyStep(
          onSuccess: () {
            final auth = context.read<AuthProvider>();
            if (auth.needsProfileSetup) {
              _goTo(_AuthStep.profileSetup);
            } else {
              _onSuccess();
            }
          },
          onBack: () => _goTo(_AuthStep.phoneInput),
        );
      case _AuthStep.emailAuth:
        return _EmailAuthStep(
          onSuccess: _onSuccess,
          onBack: () => _goTo(_AuthStep.welcome),
          onForgotPassword: _showForgotPassword,
        );
      case _AuthStep.profileSetup:
        return _ProfileSetupStep(onDone: _onSuccess);
    }
  }

  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ForgotPasswordSheet(
        onClose: () => Navigator.pop(ctx),
      ),
    );
  }
}

// ---------- Welcome ----------
class _WelcomeStep extends StatelessWidget {
  final String? action;
  final VoidCallback onPhone;
  final VoidCallback onEmail;

  const _WelcomeStep({this.action, required this.onPhone, required this.onEmail});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final subColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.primaryAccent, AppTheme.secondaryAccent],
              ),
            ),
            child: const Center(child: Text('H', style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold))),
          ),
          const SizedBox(height: 32),
          Text(
            'Welcome to Help24',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: textColor, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            action != null ? 'Sign in to $action' : 'Sign in or create an account to continue',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: subColor),
          ),
          const SizedBox(height: 48),
          _AuthButton(
            label: 'Continue with Phone',
            icon: Iconsax.call,
            onPressed: onPhone,
            primary: true,
          ),
          const SizedBox(height: 16),
          _AuthButton(
            label: 'Continue with Email',
            icon: Iconsax.sms,
            onPressed: onEmail,
            primary: false,
          ),
        ],
      ),
    );
  }
}

// ---------- Phone input ----------
class _PhoneInputStep extends StatefulWidget {
  final VoidCallback onSent;
  final VoidCallback onBack;

  const _PhoneInputStep({required this.onSent, required this.onBack});

  @override
  State<_PhoneInputStep> createState() => _PhoneInputStepState();
}

class _PhoneInputStepState extends State<_PhoneInputStep> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _normalize(String s) {
    s = s.replaceAll(RegExp(r'\s'), '');
    if (s.startsWith('+')) return s;
    if (s.startsWith('254')) return '+$s';
    if (s.startsWith('0')) return '+254${s.substring(1)}';
    if (s.length <= 9) return '+254$s';
    return '+$s';
  }

  Future<void> _send() async {
    final phone = _normalize(_controller.text);
    if (phone.length < 12) {
      context.read<AuthProvider>().setError('Please enter a valid phone number (e.g. 0712 345 678)');
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await context.read<AuthProvider>().sendOtp(phone);
    if (ok && mounted) widget.onSent();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter your phone number',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'We\'ll send you a 6-digit code (e.g. +254 7XX XXX XXX)',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
          ),
          const SizedBox(height: 28),
          if (auth.error != null) ...[
            _ErrorChip(message: auth.error!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],
          _LargeField(
            controller: _controller,
            focusNode: _focus,
            label: 'Phone number',
            hint: '+254 712 345 678',
            icon: Iconsax.call,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _send(),
            prefixText: '+254 ',
          ),
          const SizedBox(height: 32),
          _PrimaryButton(
            label: 'Send code',
            loading: auth.isLoading,
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}

// ---------- OTP verify ----------
class _OtpVerifyStep extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onBack;

  const _OtpVerifyStep({required this.onSuccess, required this.onBack});

  @override
  State<_OtpVerifyStep> createState() => _OtpVerifyStepState();
}

class _OtpVerifyStepState extends State<_OtpVerifyStep> {
  final _codeController = TextEditingController();
  int _resendSeconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.isLoggedIn) {
        auth.clearPhoneState();
        widget.onSuccess();
      }
    });
    _resendSeconds = 30;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_resendSeconds <= 0) {
        _timer?.cancel();
        if (mounted) setState(() {});
        return;
      }
      if (mounted) setState(() => _resendSeconds--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length < 6) {
      context.read<AuthProvider>().setError('Please enter the 6-digit code');
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await context.read<AuthProvider>().verifyOtp(code);
    if (ok && mounted) widget.onSuccess();
  }

  Future<void> _resend() async {
    if (_resendSeconds > 0) return;
    final ok = await context.read<AuthProvider>().resendOtp();
    if (ok && mounted) {
      setState(() => _resendSeconds = 30);
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_resendSeconds <= 0) {
          _timer?.cancel();
          if (mounted) setState(() {});
          return;
        }
        if (mounted) setState(() => _resendSeconds--);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    final phone = auth.pendingPhoneNumber ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter verification code',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'We sent a 6-digit code to $phone',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
          ),
          const SizedBox(height: 28),
          if (auth.error != null) ...[
            _ErrorChip(message: auth.error!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],
          _LargeField(
            controller: _codeController,
            label: 'Code',
            hint: '000000',
            icon: Iconsax.shield_tick,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _verify(),
            maxLength: 6,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Didn\'t receive the code? ',
                style: TextStyle(color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary, fontSize: 14),
              ),
              if (_resendSeconds > 0)
                Text(
                  'Resend in ${_resendSeconds}s',
                  style: TextStyle(color: AppTheme.darkTextTertiary, fontSize: 14),
                )
              else
                TextButton(
                  onPressed: auth.isLoading ? null : _resend,
                  child: const Text('Resend code'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          _PrimaryButton(
            label: 'Verify',
            loading: auth.isLoading,
            onPressed: _verify,
          ),
        ],
      ),
    );
  }
}

// ---------- Email auth (Sign In / Sign Up tabs) ----------
class _EmailAuthStep extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onBack;
  final VoidCallback onForgotPassword;

  const _EmailAuthStep({required this.onSuccess, required this.onBack, required this.onForgotPassword});

  @override
  State<_EmailAuthStep> createState() => _EmailAuthStepState();
}

class _EmailAuthStepState extends State<_EmailAuthStep> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _loginEmail = TextEditingController();
  final _loginPassword = TextEditingController();
  final _signupName = TextEditingController();
  final _signupEmail = TextEditingController();
  final _signupPassword = TextEditingController();
  final _signupConfirm = TextEditingController();
  bool _obscureLogin = true;
  bool _obscureSignup = true;
  bool _obscureConfirm = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _loginEmail.dispose();
    _loginPassword.dispose();
    _signupName.dispose();
    _signupEmail.dispose();
    _signupPassword.dispose();
    _signupConfirm.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final email = _loginEmail.text.trim();
    final password = _loginPassword.text;
    if (email.isEmpty || !email.contains('@')) {
      context.read<AuthProvider>().setError('Please enter a valid email address');
      return;
    }
    if (password.isEmpty) {
      context.read<AuthProvider>().setError('Please enter your password');
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await context.read<AuthProvider>().signIn(email: email, password: password);
    if (ok && mounted) widget.onSuccess();
  }

  Future<void> _signup() async {
    final name = _signupName.text.trim();
    final email = _signupEmail.text.trim();
    final password = _signupPassword.text;
    final confirm = _signupConfirm.text;
    if (name.isEmpty) {
      context.read<AuthProvider>().setError('Please enter your name');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      context.read<AuthProvider>().setError('Please enter a valid email address');
      return;
    }
    if (password.length < 6) {
      context.read<AuthProvider>().setError('Password must be at least 6 characters');
      return;
    }
    if (password != confirm) {
      context.read<AuthProvider>().setError('Passwords do not match');
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await context.read<AuthProvider>().signUp(
          email: email,
          password: password,
          name: name,
        );
    if (ok && mounted) widget.onSuccess();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Email',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: AppTheme.primaryAccent,
                borderRadius: BorderRadius.circular(12),
              ),
              labelColor: Colors.white,
              unselectedLabelColor: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              tabs: const [Tab(text: 'Sign In'), Tab(text: 'Sign Up')],
            ),
          ),
          const SizedBox(height: 24),
          if (auth.error != null) ...[
            _ErrorChip(message: auth.error!, onDismiss: auth.clearError),
            const SizedBox(height: 16),
          ],
          SizedBox(
            height: 420,
            child: TabBarView(
              controller: _tabController,
              children: [
                _LoginForm(
                  emailController: _loginEmail,
                  passwordController: _loginPassword,
                  obscurePassword: _obscureLogin,
                  onToggleObscure: () => setState(() => _obscureLogin = !_obscureLogin),
                  onForgotPassword: widget.onForgotPassword,
                  onSubmit: _login,
                  isLoading: auth.isLoading,
                  isDark: isDark,
                ),
                _SignupForm(
                  nameController: _signupName,
                  emailController: _signupEmail,
                  passwordController: _signupPassword,
                  confirmController: _signupConfirm,
                  obscurePassword: _obscureSignup,
                  obscureConfirm: _obscureConfirm,
                  onToggleObscure: () => setState(() => _obscureSignup = !_obscureSignup),
                  onToggleConfirm: () => setState(() => _obscureConfirm = !_obscureConfirm),
                  onSubmit: _signup,
                  isLoading: auth.isLoading,
                  isDark: isDark,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _PrimaryButton(
            label: _tabController.index == 0 ? 'Sign In' : 'Create account',
            loading: auth.isLoading,
            onPressed: _tabController.index == 0 ? _login : _signup,
          ),
        ],
      ),
    );
  }
}

class _LoginForm extends StatelessWidget {
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool obscurePassword;
  final VoidCallback onToggleObscure;
  final VoidCallback onForgotPassword;
  final VoidCallback onSubmit;
  final bool isLoading;
  final bool isDark;

  const _LoginForm({
    required this.emailController,
    required this.passwordController,
    required this.obscurePassword,
    required this.onToggleObscure,
    required this.onForgotPassword,
    required this.onSubmit,
    required this.isLoading,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LargeField(
            controller: emailController,
            label: 'Email',
            hint: 'you@example.com',
            icon: Iconsax.sms,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          _LargeField(
            controller: passwordController,
            label: 'Password',
            hint: '••••••••',
            icon: Iconsax.lock,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
            suffixIcon: IconButton(
              icon: Icon(obscurePassword ? Iconsax.eye_slash : Iconsax.eye, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary, size: 22),
              onPressed: onToggleObscure,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onForgotPassword,
              child: Text('Forgot password?', style: TextStyle(color: AppTheme.primaryAccent, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SignupForm extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController confirmController;
  final bool obscurePassword;
  final bool obscureConfirm;
  final VoidCallback onToggleObscure;
  final VoidCallback onToggleConfirm;
  final VoidCallback onSubmit;
  final bool isLoading;
  final bool isDark;

  const _SignupForm({
    required this.nameController,
    required this.emailController,
    required this.passwordController,
    required this.confirmController,
    required this.obscurePassword,
    required this.obscureConfirm,
    required this.onToggleObscure,
    required this.onToggleConfirm,
    required this.onSubmit,
    required this.isLoading,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LargeField(
            controller: nameController,
            label: 'Full name',
            hint: 'John Doe',
            icon: Iconsax.user,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          _LargeField(
            controller: emailController,
            label: 'Email',
            hint: 'you@example.com',
            icon: Iconsax.sms,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),
          _LargeField(
            controller: passwordController,
            label: 'Password',
            hint: 'At least 6 characters',
            icon: Iconsax.lock,
            obscureText: obscurePassword,
            textInputAction: TextInputAction.next,
            suffixIcon: IconButton(
              icon: Icon(obscurePassword ? Iconsax.eye_slash : Iconsax.eye, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary, size: 22),
              onPressed: onToggleObscure,
            ),
          ),
          const SizedBox(height: 16),
          _LargeField(
            controller: confirmController,
            label: 'Confirm password',
            hint: 'Re-enter password',
            icon: Iconsax.lock_1,
            obscureText: obscureConfirm,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
            suffixIcon: IconButton(
              icon: Icon(obscureConfirm ? Iconsax.eye_slash : Iconsax.eye, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary, size: 22),
              onPressed: onToggleConfirm,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Profile setup ----------
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
      final xFile = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
      if (xFile != null && mounted) setState(() => _pickedFile = xFile);
    } catch (_) {}
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      context.read<AuthProvider>().setError('Please enter your name');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _uploading = true);
    String? photoUrl;
    if (_pickedFile != null) {
      try {
        photoUrl = await StorageService.uploadProfileImage(
          _pickedFile!,
          context.read<AuthProvider>().currentUserId ?? '',
        );
      } catch (_) {}
    }
    setState(() => _uploading = false);
    final ok = await context.read<AuthProvider>().updateProfile(name: name, photoUrl: photoUrl);
    if (ok && mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Complete your profile',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add your name and optional photo for your account.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
          ),
          const SizedBox(height: 28),
          if (auth.error != null) ...[
            _ErrorChip(message: auth.error!, onDismiss: auth.clearError),
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
                  border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder, width: 2),
                ),
                child: _pickedFile != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Iconsax.gallery_tick, size: 40, color: AppTheme.successGreen),
                          const SizedBox(height: 4),
                          Text('Photo added', style: TextStyle(fontSize: 11, color: AppTheme.successGreen)),
                        ],
                      )
                    : Icon(Iconsax.camera, size: 40, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Add photo (optional)',
              style: TextStyle(fontSize: 13, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
            ),
          ),
          const SizedBox(height: 24),
          _LargeField(
            controller: _nameController,
            label: 'Your name',
            hint: 'John Doe',
            icon: Iconsax.user,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 32),
          _PrimaryButton(
            label: 'Continue',
            loading: auth.isLoading || _uploading,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

// ---------- Forgot password sheet ----------
class _ForgotPasswordSheet extends StatefulWidget {
  final VoidCallback onClose;

  const _ForgotPasswordSheet({required this.onClose});

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  final _emailController = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      context.read<AuthProvider>().setError('Please enter a valid email address');
      return;
    }
    FocusScope.of(context).unfocus();
    final ok = await context.read<AuthProvider>().sendPasswordResetEmail(email);
    if (ok && mounted) setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final auth = context.watch<AuthProvider>();
    return Container(
      padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 24),
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
            Icon(Icons.check_circle, color: AppTheme.successGreen, size: 56),
            const SizedBox(height: 16),
            Text(
              'Check your email',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'We sent password reset instructions to ${_emailController.text.trim()}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
            ),
            const SizedBox(height: 24),
            _PrimaryButton(label: 'Done', loading: false, onPressed: widget.onClose),
          ] else ...[
            Text(
              'Reset password',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter your email and we\'ll send you a reset link.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
            ),
            const SizedBox(height: 20),
            if (auth.error != null) ...[
              _ErrorChip(message: auth.error!, onDismiss: auth.clearError),
              const SizedBox(height: 16),
            ],
            _LargeField(
              controller: _emailController,
              label: 'Email',
              hint: 'you@example.com',
              icon: Iconsax.sms,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 24),
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

// ---------- Shared UI ----------
class _AuthButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;

  const _AuthButton({required this.label, required this.icon, required this.onPressed, this.primary = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: primary
          ? AppTheme.primaryAccent
          : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: primary ? Colors.white : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary)),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: primary ? Colors.white : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LargeField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final Widget? suffixIcon;
  final String? prefixText;
  final int? maxLength;
  final void Function(String)? onSubmitted;

  const _LargeField({
    required this.controller,
    this.focusNode,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.suffixIcon,
    this.prefixText,
    this.maxLength,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
          child: TextFormField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscureText,
            keyboardType: keyboardType,
            textInputAction: textInputAction ?? TextInputAction.next,
            textCapitalization: textCapitalization,
            onFieldSubmitted: onSubmitted,
            maxLength: maxLength,
            style: TextStyle(fontSize: 16, color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary, fontSize: 15),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 16, right: 10),
                child: Icon(icon, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary, size: 22),
              ),
              prefixText: prefixText,
              suffixIcon: suffixIcon,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              counterText: '',
            ),
          ),
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final bool loading;
  final VoidCallback onPressed;

  const _PrimaryButton({required this.label, required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryAccent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _ErrorChip extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorChip({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.errorRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.errorRed.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Iconsax.warning_2, color: AppTheme.errorRed, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.errorRed, fontSize: 14),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: AppTheme.errorRed),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}
