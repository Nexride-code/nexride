/// Self-service Change Password screen used by both the admin and support
/// portals. Themed via the [PortalSecurityTheme] constructor parameter so
/// each portal can drop in its own brand colors without forking the widget.
///
/// Flow:
///   1. Validate password complexity locally (see [validatePortalPasswordComplexity]).
///   2. Check the in-memory rate limit ([PortalRateLimiter]).
///   3. Reauthenticate, then call [PortalPasswordService.changePassword].
///   4. On success: sign the user out (the Cloud Function revoked all
///      refresh tokens) and bounce back to the login screen with a
///      success message.
///
/// When [forced] is true (because `temporaryPassword` is set), the screen
/// suppresses navigation away and explains why a rotation is required.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'portal_password_logic.dart';
import 'portal_password_service.dart';
import 'portal_security_theme.dart';

class PortalChangePasswordScreen extends StatefulWidget {
  const PortalChangePasswordScreen({
    required this.theme,
    required this.loginRoute,
    required this.successRoute,
    super.key,
    this.passwordService,
    this.forced = false,
    this.heading = 'Change password',
    this.signOutOnSuccess = true,
  });

  final PortalSecurityTheme theme;

  /// Route to navigate to when the user signs out / a forced rotation
  /// completes. Typically the portal's login route.
  final String loginRoute;

  /// Route to navigate to when an opportunistic (non-forced) password
  /// change succeeds. Typically the portal's account-security route.
  final String successRoute;

  final PortalPasswordService? passwordService;

  /// When true: the user is in a forced-rotation flow (temporaryPassword=true).
  /// We display an explanatory banner and suppress non-success navigation.
  final bool forced;

  final String heading;

  /// Whether to sign the user out and force a re-login on success. Defaults
  /// to true because the rotate Cloud Function revokes refresh tokens —
  /// any refresh after that point will fail.
  final bool signOutOnSuccess;

  @override
  State<PortalChangePasswordScreen> createState() =>
      _PortalChangePasswordScreenState();
}

class _PortalChangePasswordScreenState
    extends State<PortalChangePasswordScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _currentController = TextEditingController();
  final TextEditingController _newController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  late final PortalPasswordService _service;

  bool _busy = false;
  bool _success = false;
  String? _errorMessage;
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  @override
  void initState() {
    super.initState();
    _service = widget.passwordService ?? PortalPasswordService();
  }

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String get _rateLimitKey {
    final user = FirebaseAuth.instance.currentUser;
    return 'changepw.${user?.uid ?? 'anon'}';
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _errorMessage = null;
    });

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    final allowed = PortalRateLimiter.isAllowed(
      _rateLimitKey,
      maxAttempts: kPortalChangePwMaxAttempts,
      window: kPortalChangePwWindow,
    );
    if (!allowed) {
      final secs = PortalRateLimiter.secondsUntilReset(
        _rateLimitKey,
        window: kPortalChangePwWindow,
      );
      setState(() {
        _errorMessage =
            'Too many password-change attempts. Try again in ${formatPortalRateResetCompact(secs)}.';
      });
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email ?? '';
    final newPw = _newController.text;
    final confirmPw = _confirmController.text;

    final complexity =
        validatePortalPasswordComplexity(newPw, email: email);
    if (complexity != null) {
      setState(() => _errorMessage = complexity);
      return;
    }
    if (newPw != confirmPw) {
      setState(() => _errorMessage = 'New password and confirmation do not match.');
      return;
    }
    if (newPw == _currentController.text) {
      setState(() =>
          _errorMessage = 'New password must differ from your current password.');
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      await _service.changePassword(
        currentPassword: _currentController.text,
        newPassword: newPw,
      );
      PortalRateLimiter.clear(_rateLimitKey);
      if (!mounted) return;
      setState(() {
        _success = true;
        _busy = false;
      });
      // Slightly delay so the user sees the success state, then either
      // force sign-out (default) or navigate to the success route.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;

      if (widget.signOutOnSuccess) {
        // Refresh tokens were revoked server-side — sign out locally so the
        // app rebuilds the auth state fresh against the new credentials.
        try {
          await FirebaseAuth.instance.signOut();
        } catch (_) {
          // ignore; we're already navigating away
        }
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          widget.loginRoute,
          (Route<dynamic> _) => false,
          arguments:
              'Password updated. Sign in again with your new password to continue.',
        );
      } else {
        Navigator.of(context).pushReplacementNamed(widget.successRoute);
      }
    } on FirebaseAuthException catch (error) {
      PortalRateLimiter.recordAttempt(
        _rateLimitKey,
        window: kPortalChangePwWindow,
      );
      if (!mounted) return;
      setState(() {
        _errorMessage = friendlyPortalAuthError(error);
        _busy = false;
      });
    } catch (error) {
      PortalRateLimiter.recordAttempt(
        _rateLimitKey,
        window: kPortalChangePwWindow,
      );
      if (!mounted) return;
      setState(() {
        _errorMessage = friendlyPortalAuthError(error);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final user = FirebaseAuth.instance.currentUser;
    final attemptsLeft = PortalRateLimiter.attemptsLeft(
      _rateLimitKey,
      maxAttempts: kPortalChangePwMaxAttempts,
      window: kPortalChangePwWindow,
    );
    final allowed = attemptsLeft > 0;
    final disableSubmit = _busy || _success || !allowed;

    return Scaffold(
      backgroundColor: theme.canvas,
      appBar: AppBar(
        title: Text(widget.heading),
        backgroundColor: theme.appBarBackground,
        foregroundColor: theme.appBarForeground,
        elevation: 0,
        automaticallyImplyLeading: !widget.forced,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (widget.forced)
                      _ForcedBanner(theme: theme)
                    else
                      const SizedBox.shrink(),
                    if (widget.forced) const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: theme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            user?.email ?? '',
                            style: TextStyle(
                              color: theme.subtle,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'At least $kMinPortalPasswordLength characters. '
                            'Must include a letter and a digit. Don\'t reuse '
                            'your email handle. After a successful change, '
                            'all of your other sessions are signed out.',
                            style: TextStyle(
                              color: theme.subtle,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_errorMessage != null)
                            _InlineMessage.error(
                              theme: theme,
                              message: _errorMessage!,
                            ),
                          if (_errorMessage != null) const SizedBox(height: 12),
                          if (_success)
                            _InlineMessage.success(
                              theme: theme,
                              message: widget.signOutOnSuccess
                                  ? 'Password updated. Redirecting to sign in…'
                                  : 'Password updated. Redirecting…',
                            ),
                          if (_success) const SizedBox(height: 12),
                          _PasswordField(
                            label: 'Current password',
                            controller: _currentController,
                            obscure: _obscureCurrent,
                            autofill: AutofillHints.password,
                            onToggleObscure: () => setState(() {
                              _obscureCurrent = !_obscureCurrent;
                            }),
                            theme: theme,
                            enabled: !disableSubmit,
                          ),
                          const SizedBox(height: 12),
                          _PasswordField(
                            label: 'New password',
                            controller: _newController,
                            obscure: _obscureNew,
                            autofill: AutofillHints.newPassword,
                            onToggleObscure: () => setState(() {
                              _obscureNew = !_obscureNew;
                            }),
                            theme: theme,
                            enabled: !disableSubmit,
                          ),
                          const SizedBox(height: 12),
                          _PasswordField(
                            label: 'Confirm new password',
                            controller: _confirmController,
                            obscure: _obscureConfirm,
                            autofill: AutofillHints.newPassword,
                            onToggleObscure: () => setState(() {
                              _obscureConfirm = !_obscureConfirm;
                            }),
                            theme: theme,
                            enabled: !disableSubmit,
                          ),
                          const SizedBox(height: 16),
                          if (!allowed && !_success)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                'Locked out for ${formatPortalRateResetCompact(PortalRateLimiter.secondsUntilReset(_rateLimitKey, window: kPortalChangePwWindow))} after $kPortalChangePwMaxAttempts failed attempts.',
                                style: TextStyle(
                                  color: theme.danger,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: disableSubmit ? null : _submit,
                              style: FilledButton.styleFrom(
                                backgroundColor: theme.primary,
                                foregroundColor: theme.onPrimary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              child: _busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('Update password'),
                            ),
                          ),
                          if (!widget.forced)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Center(
                                child: TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => Navigator.of(context)
                                          .pushReplacementNamed(
                                              widget.successRoute),
                                  child: Text(
                                    'Back to account security',
                                    style: TextStyle(color: theme.primary),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForcedBanner extends StatelessWidget {
  const _ForcedBanner({required this.theme});

  final PortalSecurityTheme theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.warningBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.lock_clock_rounded,
            color: theme.warningForeground,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You\'re using a temporary password. Set a new password to '
              'continue. After saving you will be signed out of all other '
              'sessions.',
              style: TextStyle(
                color: theme.warningForeground,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage._({
    required this.theme,
    required this.message,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.border,
  });

  factory _InlineMessage.error({
    required PortalSecurityTheme theme,
    required String message,
  }) {
    return _InlineMessage._(
      theme: theme,
      message: message,
      icon: Icons.error_outline_rounded,
      background: theme.dangerBackground,
      foreground: theme.danger,
      border: theme.dangerBorder,
    );
  }

  factory _InlineMessage.success({
    required PortalSecurityTheme theme,
    required String message,
  }) {
    return _InlineMessage._(
      theme: theme,
      message: message,
      icon: Icons.check_circle_outline_rounded,
      background: theme.successBackground,
      foreground: theme.success,
      border: theme.successBorder,
    );
  }

  final PortalSecurityTheme theme;
  final String message;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color border;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: foreground, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: foreground, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.label,
    required this.controller,
    required this.obscure,
    required this.onToggleObscure,
    required this.theme,
    required this.autofill,
    required this.enabled,
  });

  final String label;
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final PortalSecurityTheme theme;
  final String autofill;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      enableSuggestions: false,
      autocorrect: false,
      enabled: enabled,
      autofillHints: <String>[autofill],
      validator: (String? value) {
        if (value == null || value.isEmpty) {
          return '$label is required.';
        }
        return null;
      },
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: theme.primary, width: 1.5),
        ),
        suffixIcon: IconButton(
          tooltip: obscure ? 'Show password' : 'Hide password',
          onPressed: enabled ? onToggleObscure : null,
          icon: Icon(
            obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
    );
  }
}
