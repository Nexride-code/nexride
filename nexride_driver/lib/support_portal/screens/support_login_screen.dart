import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';
import '../../portal_security/portal_forgot_password_dialog.dart';
import '../services/support_auth_service.dart';
import '../support_config.dart';

class SupportLoginScreen extends StatefulWidget {
  const SupportLoginScreen({
    super.key,
    this.inlineMessage,
    this.authService,
    required this.dashboardRoute,
  });

  final String? inlineMessage;
  final SupportAuthService? authService;
  final String dashboardRoute;

  @override
  State<SupportLoginScreen> createState() => _SupportLoginScreenState();
}

class _SupportLoginScreenState extends State<SupportLoginScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  late final SupportAuthService _authService;
  late final AnimationController _animationController;
  late final Animation<Color?> _startColor;
  late final Animation<Color?> _endColor;

  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? SupportAuthService();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);
    _startColor = ColorTween(
      begin: const Color(0xFF111923),
      end: const Color(0xFF213246),
    ).animate(_animationController);
    _endColor = ColorTween(
      begin: const Color(0xFF1A1F25),
      end: const Color(0xFF6A4A1F),
    ).animate(_animationController);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() {
        _errorMessage = null;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _authService.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil(
        widget.dashboardRoute,
        (Route<dynamic> route) => false,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.toString().replaceFirst('Bad state: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (BuildContext context, Widget? child) {
        return Scaffold(
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[
                  _startColor.value ?? const Color(0xFF111923),
                  _endColor.value ?? const Color(0xFF6A4A1F),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: LayoutBuilder(
                      builder: (
                        BuildContext context,
                        BoxConstraints constraints,
                      ) {
                        final stacked = constraints.maxWidth < 860;
                        final infoPane = _buildInfoPane();
                        final formPane = _buildFormPane();
                        if (stacked) {
                          return Column(
                            children: <Widget>[
                              infoPane,
                              const SizedBox(height: 18),
                              formPane,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(child: infoPane),
                            const SizedBox(width: 18),
                            SizedBox(width: 390, child: formPane),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoPane() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(34),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE3A9).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.support_agent_rounded,
              color: AdminThemeTokens.gold,
              size: 32,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'NEXRIDE SUPPORT WORKSPACE',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'NexRide Support Portal',
            style: TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              height: 1.02,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Dedicated support login for complaints, disputes, reports, escalations, and ticket conversations without exposing admin-only finance or pricing controls.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.76),
              fontSize: 15,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 22),
          const Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _SupportFeatureChip('Role-based access'),
              _SupportFeatureChip('Ticket threads'),
              _SupportFeatureChip('Assignment + escalation'),
              _SupportFeatureChip('SLA aging'),
              _SupportFeatureChip('Staff audit trail'),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Allowed access roles',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 12),
                _SupportInfoLine('support_agent'),
                _SupportInfoLine('support_manager'),
                _SupportInfoLine('admin role override'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormPane() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFE6DDCF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Sign in',
            style: TextStyle(
              color: Color(0xFF121212),
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Use your support or admin credentials to open the NexRide support workspace.',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.65),
              fontSize: 14,
              height: 1.5,
            ),
          ),
          if (widget.inlineMessage?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 18),
            _buildMessageCard(
              widget.inlineMessage!,
              color: const Color(0xFFEFF5FF),
              icon: Icons.info_outline_rounded,
            ),
          ],
          if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 18),
            _buildMessageCard(
              _errorMessage!,
              color: const Color(0xFFFFEEEE),
              icon: Icons.error_outline_rounded,
            ),
          ],
          const SizedBox(height: 22),
          Form(
            key: _formKey,
            child: AutofillGroup(
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[AutofillHints.username],
                    decoration: _inputDecoration('Email address'),
                    validator: (String? value) {
                      final text = value?.trim() ?? '';
                      if (text.isEmpty) {
                        return 'Enter your support email.';
                      }
                      if (!text.contains('@')) {
                        return 'Enter a valid email address.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    autofillHints: const <String>[AutofillHints.password],
                    onFieldSubmitted: (_) => _isLoading ? null : _signIn(),
                    decoration: _inputDecoration(
                      'Password',
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                    validator: (String? value) {
                      final text = value?.trim() ?? '';
                      if (text.isEmpty) {
                        return 'Enter your password.';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _signIn,
              style: ElevatedButton.styleFrom(
                backgroundColor: AdminThemeTokens.gold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Text('Open support portal'),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _isLoading ? null : _openForgotPassword,
              style: TextButton.styleFrom(
                foregroundColor: AdminThemeTokens.gold,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
              child: const Text(
                'Forgot password?',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openForgotPassword() async {
    await showPortalForgotPasswordDialog(
      context,
      theme: SupportThemeTokens.portalSecurityTheme,
      initialEmail: _emailController.text.trim().isEmpty
          ? null
          : _emailController.text.trim(),
    );
  }

  Widget _buildMessageCard(
    String message, {
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: Colors.black.withValues(alpha: 0.65)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF2E2A25),
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(
    String label, {
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFFF8F4EC),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE1D9CA)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE1D9CA)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: AdminThemeTokens.gold, width: 1.4),
      ),
    );
  }
}

class _SupportFeatureChip extends StatelessWidget {
  const _SupportFeatureChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SupportInfoLine extends StatelessWidget {
  const _SupportInfoLine(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.check_circle_outline_rounded,
            color: AdminThemeTokens.gold,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.82),
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
