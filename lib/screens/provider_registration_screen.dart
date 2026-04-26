import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/provider_service.dart';
import '../theme/app_theme.dart';

class ProviderRegistrationScreen extends StatefulWidget {
  /// Pass the user's stored phone (e.g. +254712345678) to prefill the login
  /// phone field. If null the field starts empty.
  final String? initialLoginPhone;

  const ProviderRegistrationScreen({super.key, this.initialLoginPhone});

  @override
  State<ProviderRegistrationScreen> createState() =>
      _ProviderRegistrationScreenState();
}

class _ProviderRegistrationScreenState
    extends State<ProviderRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _phoneLoginController = TextEditingController();
  final _phonePayoutController = TextEditingController();
  final _phonePayoutConfirmController = TextEditingController();

  final List<String> _selectedServices = [];
  bool _submitting = false;
  bool _success = false;
  String? _submitError;

  static const List<String> _services = [
    'Cleaning', 'Plumbing', 'Electrical', 'Painting', 'Carpentry',
    'Gardening', 'Delivery', 'Moving', 'IT & Tech', 'Design',
    'Cooking', 'Beauty & Wellness', 'Tutoring', 'Driving',
    'Security', 'Events', 'Photography', 'Other',
  ];

  @override
  void initState() {
    super.initState();
    final display = ProviderService.toDisplayPhone(widget.initialLoginPhone);
    if (display.isNotEmpty) _phoneLoginController.text = display;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _phoneLoginController.dispose();
    _phonePayoutController.dispose();
    _phonePayoutConfirmController.dispose();
    super.dispose();
  }

  // ── Validators ────────────────────────────────────────────────────────────

  String? _validateRequired(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  String? _validatePhone(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final d = v.replaceAll(RegExp(r'\D'), '');
    if (d.length != 9) return '9 digits required (e.g. 712 345 678)';
    return null;
  }

  String? _validatePayoutConfirm(String? v) {
    final phoneErr = _validatePhone(v);
    if (phoneErr != null) return phoneErr;
    final a = _phonePayoutController.text.replaceAll(RegExp(r'\D'), '');
    final b = (v ?? '').replaceAll(RegExp(r'\D'), '');
    if (a != b) return 'Numbers do not match';
    return null;
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedServices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Pick at least one service you offer'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() { _submitting = true; _submitError = null; });

    try {
      await ProviderService.registerProvider(
        name: _nameController.text.trim(),
        phoneLogin: _phoneLoginController.text.trim(),
        phonePayout: _phonePayoutController.text.trim(),
        services: List<String>.from(_selectedServices),
        location: _locationController.text.trim(),
      );
      if (mounted) setState(() { _submitting = false; _success = true; });
    } on ProviderServiceException catch (e) {
      if (mounted) setState(() { _submitting = false; _submitError = e.message; });
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitError = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: _submitting
            ? const SizedBox.shrink()
            : IconButton(
                icon: Icon(Icons.close, color: textPrimary),
                onPressed: () => Navigator.of(context).pop(),
              ),
        title: Text(
          'Join as Provider',
          style: TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: _success ? _buildSuccess(isDark) : _buildForm(isDark),
      ),
    );
  }

  // ── Form ──────────────────────────────────────────────────────────────────

  Widget _buildForm(bool isDark) {
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Stack(
      children: [
        Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
            children: [
              // Submit error banner
              if (_submitError != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.errorRed.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.errorRed.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: AppTheme.errorRed, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _submitError!,
                          style: const TextStyle(
                              color: AppTheme.errorRed, fontSize: 13),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => setState(() => _submitError = null),
                        child: const Icon(Icons.close,
                            color: AppTheme.errorRed, size: 16),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── Name ──────────────────────────────────────────────────
              _Label('Your name or business name', isDark: isDark),
              const SizedBox(height: 8),
              _AppField(
                controller: _nameController,
                hint: 'e.g. John Mwangi Services',
                icon: Icons.person_outline,
                isDark: isDark,
                validator: _validateRequired,
              ),

              const SizedBox(height: 20),

              // ── Location ──────────────────────────────────────────────
              _Label('Where do you operate?', isDark: isDark),
              const SizedBox(height: 8),
              _AppField(
                controller: _locationController,
                hint: 'e.g. Westlands, Nairobi',
                icon: Icons.location_on_outlined,
                isDark: isDark,
                validator: _validateRequired,
              ),

              const SizedBox(height: 24),

              // ── Services ──────────────────────────────────────────────
              _Label('Services you offer', isDark: isDark),
              Text('Tap to select — pick all that apply',
                  style: TextStyle(color: textSecondary, fontSize: 12)),
              const SizedBox(height: 12),

              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _services.map((s) {
                  final on = _selectedServices.contains(s);
                  return GestureDetector(
                    onTap: () => setState(() =>
                        on ? _selectedServices.remove(s) : _selectedServices.add(s)),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: on ? AppTheme.primaryAccent : cardBg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: on ? AppTheme.primaryAccent : borderColor,
                        ),
                      ),
                      child: Text(
                        s,
                        style: TextStyle(
                          color: on ? Colors.white : textSecondary,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              if (_selectedServices.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '${_selectedServices.length} selected',
                  style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w500),
                ),
              ],

              const SizedBox(height: 28),

              // ── Phone divider ──────────────────────────────────────────
              Row(
                children: [
                  Expanded(child: Divider(color: borderColor)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('Phone numbers',
                        style: TextStyle(
                            color: textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500)),
                  ),
                  Expanded(child: Divider(color: borderColor)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Enter the last 9 digits. We add +254 automatically.',
                style: TextStyle(color: textSecondary, fontSize: 12),
              ),

              const SizedBox(height: 16),

              // ── Login phone ───────────────────────────────────────────
              _Label('Login phone', isDark: isDark),
              Text('The number linked to your Help24 account',
                  style: TextStyle(color: textSecondary, fontSize: 12)),
              const SizedBox(height: 8),
              _PhoneField(
                controller: _phoneLoginController,
                isDark: isDark,
                validator: _validatePhone,
              ),

              const SizedBox(height: 20),

              // ── Payout phone ──────────────────────────────────────────
              _Label('Payout phone', isDark: isDark),
              Text('Earnings sent here after each job',
                  style: TextStyle(color: textSecondary, fontSize: 12)),
              const SizedBox(height: 8),
              _PhoneField(
                controller: _phonePayoutController,
                isDark: isDark,
                validator: _validatePhone,
                onChanged: (_) {
                  // Re-trigger confirm validation when payout changes
                  _formKey.currentState?.validate();
                },
              ),

              const SizedBox(height: 20),

              // ── Confirm payout ────────────────────────────────────────
              _Label('Confirm payout phone', isDark: isDark),
              const SizedBox(height: 8),
              _PhoneField(
                controller: _phonePayoutConfirmController,
                isDark: isDark,
                validator: _validatePayoutConfirm,
                icon: Icons.check_circle_outline,
              ),

              const SizedBox(height: 32),
            ],
          ),
        ),

        // Floating submit button
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Register as Provider',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Success ───────────────────────────────────────────────────────────────

  Widget _buildSuccess(bool isDark) {
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryAccent, AppTheme.secondaryAccent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryAccent.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(Icons.verified_rounded,
                  color: Colors.white, size: 48),
            ),
            const SizedBox(height: 32),
            Text(
              "You're now a service provider!",
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 24),
            ),
            const SizedBox(height: 14),
            Text(
              'Your profile is live. Clients on Help24 can find you and reach out directly.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: textSecondary, fontSize: 15, height: 1.5),
            ),
            const SizedBox(height: 48),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Go to Discover',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Field helpers ─────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  final bool isDark;
  const _Label(this.text, {required this.isDark});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      );
}

class _AppField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool isDark;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  const _AppField({
    required this.controller,
    required this.hint,
    required this.icon,
    required this.isDark,
    this.validator,
    this.keyboardType,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validator: validator,
      style: TextStyle(color: textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: textSecondary),
        prefixIcon: Icon(icon, color: AppTheme.primaryAccent, size: 20),
        filled: true,
        fillColor: cardBg,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderColor)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderColor)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: AppTheme.primaryAccent, width: 1.5)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppTheme.errorRed)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: AppTheme.errorRed, width: 1.5)),
      ),
    );
  }
}

/// Phone field that shows +254 as a static prefix. User types 9 digits only.
class _PhoneField extends StatelessWidget {
  final TextEditingController controller;
  final bool isDark;
  final String? Function(String?)? validator;
  final IconData icon;
  final ValueChanged<String>? onChanged;

  const _PhoneField({
    required this.controller,
    required this.isDark,
    this.validator,
    this.icon = Icons.phone_outlined,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(9),
      ],
      validator: validator,
      onChanged: onChanged,
      style: TextStyle(color: textPrimary, letterSpacing: 1.2),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppTheme.primaryAccent, size: 20),
        // Static +254 shown inline before the cursor
        prefixText: '+254 ',
        prefixStyle: TextStyle(
            color: textPrimary, fontWeight: FontWeight.w500, fontSize: 16),
        hintText: '712 345 678',
        hintStyle: TextStyle(
            color: textSecondary, letterSpacing: 0, fontSize: 15),
        filled: true,
        fillColor: cardBg,
        counterText: '',
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderColor)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: borderColor)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: AppTheme.primaryAccent, width: 1.5)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppTheme.errorRed)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                const BorderSide(color: AppTheme.errorRed, width: 1.5)),
      ),
    );
  }
}
