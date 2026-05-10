import 'package:flutter/material.dart';

import '../../portal_security/portal_forgot_password_dialog.dart';
import '../admin_config.dart';
import '../services/admin_auth_service.dart';

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({
    super.key,
    this.inlineMessage,
    this.authService,
    this.dashboardRoute = AdminRoutePaths.admin,
  });

  final String? inlineMessage;
  final AdminAuthService? authService;
  final String dashboardRoute;

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  late final AdminAuthService _authService;
  late final AnimationController _animationController;
  late final Animation<Color?> _startColor;
  late final Animation<Color?> _endColor;

  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? AdminAuthService();
    debugPrint(
      '[AdminLogin] init inlineMessage=${widget.inlineMessage ?? '(none)'}',
    );
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);
    _startColor = ColorTween(
      begin: const Color(0xFF101010),
      end: const Color(0xFF2F2416),
    ).animate(_animationController);
    _endColor = ColorTween(
      begin: const Color(0xFF1B1B1A),
      end: const Color(0xFF6E4E22),
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
      debugPrint(
        '[AdminLogin] attempting email/password sign-in for ${_emailController.text.trim()}',
      );
      await _authService.signIn(
        email: _emailController.text,
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }
      debugPrint(
        '[AdminLogin] admin sign-in succeeded, routing to ${widget.dashboardRoute}',
      );
      Navigator.of(context).pushNamedAndRemoveUntil(
        widget.dashboardRoute,
        (Route<dynamic> route) => false,
      );
    } catch (error) {
      debugPrint('[AdminLogin] admin sign-in failed: $error');
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
                  _startColor.value ?? const Color(0xFF101010),
                  _endColor.value ?? const Color(0xFF6E4E22),
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
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                        final stacked = constraints.maxWidth < 840;
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
                            SizedBox(width: 380, child: formPane),
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
              Icons.apartment_rounded,
              color: Color(0xFFB57A2A),
              size: 30,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'NexRide Control Center',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.70),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'NexRide Admin',
            style: TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w800,
              height: 1.02,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Operations, control, monitoring, finance, payouts, pricing, subscriptions, verification, and issue visibility in one branded control center.',
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
              _LoginFeatureChip('Live riders + drivers'),
              _LoginFeatureChip('Trips + route logs'),
              _LoginFeatureChip('Finance + withdrawals'),
              _LoginFeatureChip('Pricing + subscriptions'),
              _LoginFeatureChip('Verification + support'),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Admin access methods',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                _infoLine('Firebase Auth email/password sign-in'),
                _infoLine('Access granted by admin role assignment'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormPane() {
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x20000000),
            blurRadius: 28,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Admin sign in',
            style: TextStyle(
              color: Color(0xFF121212),
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Use a Firebase-authenticated admin account to open the NexRide control center.',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.64),
              height: 1.5,
            ),
          ),
          if (widget.inlineMessage?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 16),
            _inlineCallout(widget.inlineMessage!, Colors.blue.shade50,
                Colors.blue.shade800),
          ],
          if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 16),
            _inlineCallout(_errorMessage!, const Color(0xFFFFF0EE),
                const Color(0xFFD64545)),
          ],
          const SizedBox(height: 18),
          Form(
            key: _formKey,
            child: AutofillGroup(
              child: Column(
                children: <Widget>[
                  TextFormField(
                    controller: _emailController,
                    decoration: _inputDecoration('Admin email'),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[AutofillHints.username],
                    validator: (String? value) {
                      final text = value?.trim() ?? '';
                      if (text.isEmpty) {
                        return 'Enter your admin email.';
                      }
                      if (!text.contains('@')) {
                        return 'Enter a valid email address.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
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
                    obscureText: _obscurePassword,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    autofillHints: const <String>[AutofillHints.password],
                    onFieldSubmitted: (_) => _isLoading ? null : _signIn(),
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
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _signIn,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB57A2A),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w800),
              ),
              child: Text(
                  _isLoading ? 'Signing in...' : 'Open admin control center'),
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: TextButton(
              onPressed: _isLoading ? null : _openForgotPassword,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFB57A2A),
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
      theme: AdminThemeTokens.portalSecurityTheme,
      initialEmail: _emailController.text.trim().isEmpty
          ? null
          : _emailController.text.trim(),
    );
  }

  Widget _inlineCallout(String text, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w600,
          height: 1.45,
        ),
      ),
    );
  }

  Widget _infoLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFB57A2A).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.74),
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
      fillColor: const Color(0xFFF7F3EC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE7DDCF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFE7DDCF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: Color(0xFFB57A2A), width: 1.4),
      ),
    );
  }
}

class _LoginFeatureChip extends StatelessWidget {
  const _LoginFeatureChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.86),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
