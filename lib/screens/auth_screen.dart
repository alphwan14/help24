import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';

/// Premium Authentication screen with Login and Sign Up tabs
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

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }
  
  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF0A0A0F) : AppTheme.lightBackground,
        body: SafeArea(
          child: Column(
            children: [
              // Custom App Bar
              _buildAppBar(context, isDark),
              
              // Content
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        const SizedBox(height: 20),
                        
                        // Logo & Welcome
                        _buildHeader(context, isDark)
                            .animate()
                            .fadeIn(duration: 400.ms)
                            .slideY(begin: -0.1, end: 0),
                        
                        const SizedBox(height: 32),
                        
                        // Tab Switcher
                        _buildTabSwitcher(context, isDark)
                            .animate()
                            .fadeIn(duration: 400.ms, delay: 100.ms),
                        
                        const SizedBox(height: 24),
                        
                        // Form Content
                        AnimatedBuilder(
                          animation: _tabController,
                          builder: (context, child) {
                            return AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: _tabController.index == 0
                                  ? _LoginForm(
                                      key: const ValueKey('login'),
                                      onSuccess: widget.onSuccess ?? () => Navigator.pop(context, true),
                                      onForgotPassword: _showForgotPassword,
                                      onSwitchToSignUp: () => _tabController.animateTo(1),
                                    )
                                  : _SignUpForm(
                                      key: const ValueKey('signup'),
                                      onSuccess: widget.onSuccess ?? () => Navigator.pop(context, true),
                                      onSwitchToSignIn: () => _tabController.animateTo(0),
                                    ),
                            );
                          },
                        ),
                        
                        const SizedBox(height: 32),
                      ],
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
  
  Widget _buildAppBar(BuildContext context, bool isDark) {
    if (widget.isModal) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Spacer(),
            IconButton(
              onPressed: () => Navigator.pop(context, false),
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.close,
                  color: isDark ? Colors.white70 : Colors.black54,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      );
    }
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context, false),
            icon: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                ),
              ),
              child: Icon(
                Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black87,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildHeader(BuildContext context, bool isDark) {
    return Column(
      children: [
        // Premium Logo
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.primaryAccent,
                AppTheme.primaryAccent.withValues(alpha: 0.8),
                AppTheme.secondaryAccent,
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryAccent.withValues(alpha: 0.4),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: AppTheme.primaryAccent.withValues(alpha: 0.2),
                blurRadius: 64,
                offset: const Offset(0, 24),
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'H',
              style: TextStyle(
                color: Colors.white,
                fontSize: 42,
                fontWeight: FontWeight.bold,
                letterSpacing: -2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        
        // Title
        Text(
          'Welcome Back',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 8),
        
        // Subtitle
        Text(
          widget.action != null 
              ? 'Sign in to ${widget.action}'
              : 'Sign in to continue to Help24',
          style: TextStyle(
            fontSize: 16,
            color: isDark ? Colors.white54 : Colors.black45,
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
  
  Widget _buildTabSwitcher(BuildContext context, bool isDark) {
    return Container(
      height: 56,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppTheme.primaryAccent,
              AppTheme.primaryAccent.withValues(alpha: 0.9),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primaryAccent.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: Colors.white,
        unselectedLabelColor: isDark ? Colors.white54 : Colors.black45,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        dividerColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
        tabs: const [
          Tab(text: 'Sign In'),
          Tab(text: 'Create Account'),
        ],
      ),
    );
  }
  
  void _showForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const _ForgotPasswordModal(),
    );
  }
}

/// Premium Login Form
class _LoginForm extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onForgotPassword;
  final VoidCallback onSwitchToSignUp;
  
  const _LoginForm({
    super.key,
    required this.onSuccess,
    required this.onForgotPassword,
    required this.onSwitchToSignUp,
  });
  
  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _obscurePassword = true;
  
  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }
  
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    
    // Hide keyboard
    FocusScope.of(context).unfocus();
    
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.signIn(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );
    
    if (success && mounted) {
      widget.onSuccess();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Consumer<AuthProvider>(
      builder: (context, auth, child) {
        return Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Error Alert
              if (auth.error != null)
                _ErrorAlert(
                  message: auth.error!,
                  onDismiss: auth.clearError,
                ).animate().fadeIn().shake(hz: 2, duration: 400.ms),
              
              if (auth.error != null) const SizedBox(height: 20),
              
              // Email Field
              _PremiumTextField(
                controller: _emailController,
                focusNode: _emailFocus,
                label: 'Email Address',
                hint: 'you@example.com',
                icon: Iconsax.sms,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Email is required';
                  }
                  if (!value.contains('@') || !value.contains('.')) {
                    return 'Enter a valid email address';
                  }
                  return null;
                },
              ).animate().fadeIn(delay: 150.ms).slideX(begin: -0.05, end: 0),
              
              const SizedBox(height: 20),
              
              // Password Field
              _PremiumTextField(
                controller: _passwordController,
                focusNode: _passwordFocus,
                label: 'Password',
                hint: 'Enter your password',
                icon: Iconsax.lock,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Iconsax.eye_slash : Iconsax.eye,
                    color: isDark ? Colors.white38 : Colors.black38,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Password is required';
                  }
                  return null;
                },
              ).animate().fadeIn(delay: 200.ms).slideX(begin: -0.05, end: 0),
              
              const SizedBox(height: 12),
              
              // Forgot Password
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.onForgotPassword,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  child: Text(
                    'Forgot Password?',
                    style: TextStyle(
                      color: AppTheme.primaryAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 28),
              
              // Submit Button
              _PremiumButton(
                label: 'Sign In',
                isLoading: auth.isLoading,
                onPressed: _submit,
              ).animate().fadeIn(delay: 250.ms).slideY(begin: 0.1, end: 0),
              
              const SizedBox(height: 28),
              
              // Divider
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'New to Help24?',
                      style: TextStyle(
                        color: isDark ? Colors.white38 : Colors.black38,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 20),
              
              // Switch to Sign Up
              _SecondaryButton(
                label: 'Create an Account',
                onPressed: widget.onSwitchToSignUp,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Premium Sign Up Form
class _SignUpForm extends StatefulWidget {
  final VoidCallback onSuccess;
  final VoidCallback onSwitchToSignIn;
  
  const _SignUpForm({
    super.key,
    required this.onSuccess,
    required this.onSwitchToSignIn,
  });
  
  @override
  State<_SignUpForm> createState() => _SignUpFormState();
}

class _SignUpFormState extends State<_SignUpForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  
  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }
  
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    
    FocusScope.of(context).unfocus();
    
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.signUp(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      name: _nameController.text.trim(),
    );
    
    if (success && mounted) {
      widget.onSuccess();
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Consumer<AuthProvider>(
      builder: (context, auth, child) {
        return Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Error Alert
              if (auth.error != null)
                _ErrorAlert(
                  message: auth.error!,
                  onDismiss: auth.clearError,
                ).animate().fadeIn().shake(hz: 2, duration: 400.ms),
              
              if (auth.error != null) const SizedBox(height: 20),
              
              // Name Field
              _PremiumTextField(
                controller: _nameController,
                label: 'Full Name',
                hint: 'John Doe',
                icon: Iconsax.user,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Name is required';
                  }
                  return null;
                },
              ).animate().fadeIn(delay: 150.ms).slideX(begin: -0.05, end: 0),
              
              const SizedBox(height: 20),
              
              // Email Field
              _PremiumTextField(
                controller: _emailController,
                label: 'Email Address',
                hint: 'you@example.com',
                icon: Iconsax.sms,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Email is required';
                  }
                  if (!value.contains('@') || !value.contains('.')) {
                    return 'Enter a valid email address';
                  }
                  return null;
                },
              ).animate().fadeIn(delay: 200.ms).slideX(begin: -0.05, end: 0),
              
              const SizedBox(height: 20),
              
              // Password Field
              _PremiumTextField(
                controller: _passwordController,
                label: 'Password',
                hint: 'At least 6 characters',
                icon: Iconsax.lock,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.next,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Iconsax.eye_slash : Iconsax.eye,
                    color: isDark ? Colors.white38 : Colors.black38,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Password is required';
                  }
                  if (value.length < 6) {
                    return 'Password must be at least 6 characters';
                  }
                  return null;
                },
              ).animate().fadeIn(delay: 250.ms).slideX(begin: -0.05, end: 0),
              
              const SizedBox(height: 20),
              
              // Confirm Password Field
              _PremiumTextField(
                controller: _confirmPasswordController,
                label: 'Confirm Password',
                hint: 'Re-enter your password',
                icon: Iconsax.lock_1,
                obscureText: _obscureConfirmPassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureConfirmPassword ? Iconsax.eye_slash : Iconsax.eye,
                    color: isDark ? Colors.white38 : Colors.black38,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please confirm your password';
                  }
                  if (value != _passwordController.text) {
                    return 'Passwords do not match';
                  }
                  return null;
                },
              ).animate().fadeIn(delay: 300.ms).slideX(begin: -0.05, end: 0),
              
              const SizedBox(height: 32),
              
              // Submit Button
              _PremiumButton(
                label: 'Create Account',
                isLoading: auth.isLoading,
                onPressed: _submit,
              ).animate().fadeIn(delay: 350.ms).slideY(begin: 0.1, end: 0),
              
              const SizedBox(height: 28),
              
              // Divider
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 1,
                      color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Already have an account?',
                      style: TextStyle(
                        color: isDark ? Colors.white38 : Colors.black38,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      height: 1,
                      color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 20),
              
              // Switch to Sign In
              _SecondaryButton(
                label: 'Sign In Instead',
                onPressed: widget.onSwitchToSignIn,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Premium Text Field
class _PremiumTextField extends StatelessWidget {
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
  final String? Function(String?)? validator;
  final void Function(String)? onSubmitted;
  
  const _PremiumTextField({
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
    this.validator,
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
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.08),
            ),
          ),
          child: TextFormField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscureText,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            textCapitalization: textCapitalization,
            onFieldSubmitted: onSubmitted,
            style: TextStyle(
              fontSize: 16,
              color: isDark ? Colors.white : Colors.black87,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                color: isDark ? Colors.white30 : Colors.black26,
                fontSize: 15,
              ),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 16, right: 12),
                child: Icon(
                  icon,
                  color: isDark ? Colors.white30 : Colors.black26,
                  size: 22,
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 54),
              suffixIcon: suffixIcon,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              errorStyle: TextStyle(
                color: AppTheme.errorRed,
                fontSize: 12,
              ),
            ),
            validator: validator,
          ),
        ),
      ],
    );
  }
}

/// Premium Primary Button
class _PremiumButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final VoidCallback onPressed;
  
  const _PremiumButton({
    required this.label,
    required this.isLoading,
    required this.onPressed,
  });
  
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.primaryAccent,
            AppTheme.primaryAccent.withValues(alpha: 0.9),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryAccent.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isLoading ? null : onPressed,
          borderRadius: BorderRadius.circular(18),
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    label,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Secondary Button
class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  
  const _SecondaryButton({
    required this.label,
    required this.onPressed,
  });
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.08),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Error Alert
class _ErrorAlert extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  
  const _ErrorAlert({
    required this.message,
    required this.onDismiss,
  });
  
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.errorRed.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppTheme.errorRed.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.errorRed.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Iconsax.warning_2,
              color: AppTheme.errorRed,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppTheme.errorRed,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(
              Icons.close,
              color: AppTheme.errorRed.withValues(alpha: 0.6),
              size: 20,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

/// Forgot Password Modal
class _ForgotPasswordModal extends StatefulWidget {
  const _ForgotPasswordModal();
  
  @override
  State<_ForgotPasswordModal> createState() => _ForgotPasswordModalState();
}

class _ForgotPasswordModalState extends State<_ForgotPasswordModal> {
  final _emailController = TextEditingController();
  bool _isLoading = false;
  bool _emailSent = false;
  String? _error;
  
  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }
  
  Future<void> _submit() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Please enter a valid email address');
      return;
    }
    
    setState(() {
      _isLoading = true;
      _error = null;
    });
    
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.sendPasswordResetEmail(email);
    
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (success) {
          _emailSent = true;
        } else {
          _error = authProvider.error ?? 'Failed to send reset email';
        }
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0A0A0F) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 28),
          
          if (_emailSent) ...[
            // Success State
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Iconsax.tick_circle5,
                color: AppTheme.successGreen,
                size: 40,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Check Your Email',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'We\'ve sent password reset instructions to your email address.',
              style: TextStyle(
                fontSize: 15,
                color: isDark ? Colors.white54 : Colors.black45,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            _PremiumButton(
              label: 'Done',
              isLoading: false,
              onPressed: () => Navigator.pop(context),
            ),
          ] else ...[
            // Form State
            Text(
              'Reset Password',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Enter your email and we\'ll send you instructions to reset your password.',
              style: TextStyle(
                fontSize: 15,
                color: isDark ? Colors.white54 : Colors.black45,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 28),
            
            if (_error != null) ...[
              _ErrorAlert(
                message: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
              const SizedBox(height: 20),
            ],
            
            _PremiumTextField(
              controller: _emailController,
              label: 'Email Address',
              hint: 'you@example.com',
              icon: Iconsax.sms,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 28),
            
            _PremiumButton(
              label: 'Send Reset Link',
              isLoading: _isLoading,
              onPressed: _submit,
            ),
          ],
        ],
      ),
    );
  }
}
