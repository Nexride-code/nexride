/// Forgot Password dialog used by both admin and support login screens.
///
/// Always shows a generic success message — never reveals whether an
/// account exists for the entered email — so it can't be used as an
/// account-enumeration oracle.
///
/// Local rate limit (3 sends per 30 min per email) is layered on top of
/// Firebase Auth's per-IP / per-account throttle.
library;

import 'package:flutter/material.dart';

import 'portal_password_logic.dart';
import 'portal_password_service.dart';
import 'portal_security_theme.dart';

/// Convenience: show the dialog and await its dismissal.
Future<void> showPortalForgotPasswordDialog(
  BuildContext context, {
  required PortalSecurityTheme theme,
  String? initialEmail,
  PortalPasswordService? passwordService,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) => PortalForgotPasswordDialog(
      theme: theme,
      initialEmail: initialEmail,
      passwordService: passwordService,
    ),
  );
}

class PortalForgotPasswordDialog extends StatefulWidget {
  const PortalForgotPasswordDialog({
    required this.theme,
    super.key,
    this.initialEmail,
    this.passwordService,
  });

  final PortalSecurityTheme theme;
  final String? initialEmail;
  final PortalPasswordService? passwordService;

  @override
  State<PortalForgotPasswordDialog> createState() =>
      _PortalForgotPasswordDialogState();
}

class _PortalForgotPasswordDialogState extends State<PortalForgotPasswordDialog> {
  late final TextEditingController _controller;
  late final PortalPasswordService _service;

  bool _busy = false;
  bool _done = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialEmail ?? '');
    _service = widget.passwordService ?? PortalPasswordService();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _rateKey {
    final email = _controller.text.trim().toLowerCase();
    return 'reset.${email.isEmpty ? 'anon' : email}';
  }

  Future<void> _submit() async {
    setState(() => _errorMessage = null);
    final email = _controller.text.trim();
    if (email.isEmpty) {
      setState(() => _errorMessage = 'Enter the email associated with your account.');
      return;
    }
    final allowed = PortalRateLimiter.isAllowed(
      _rateKey,
      maxAttempts: kPortalResetEmailMaxAttempts,
      window: kPortalResetEmailWindow,
    );
    if (!allowed) {
      final secs = PortalRateLimiter.secondsUntilReset(
        _rateKey,
        window: kPortalResetEmailWindow,
      );
      setState(() {
        _errorMessage =
            'Too many reset requests for that email. Try again in ${formatPortalRateResetCompact(secs)}.';
      });
      return;
    }

    setState(() => _busy = true);
    PortalRateLimiter.recordAttempt(
      _rateKey,
      window: kPortalResetEmailWindow,
    );
    try {
      await _service.sendPasswordReset(email: email);
    } catch (_) {
      // Service swallows expected errors, but be defensive in case.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(_done ? 'Reset link sent' : 'Reset your password'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_done)
              Text(
                'If an account exists for ${_controller.text.trim().isEmpty ? "that email" : _controller.text.trim()}, '
                'we\'ve sent a password-reset link. Check your inbox (and spam) — '
                'links expire in about an hour. If you don\'t receive anything, '
                'contact a NexRide system administrator.',
                style: TextStyle(color: theme.subtle, fontSize: 13, height: 1.45),
              )
            else ...<Widget>[
              Text(
                'Enter the email associated with your operator account. We\'ll '
                'email a password-reset link if it matches.',
                style: TextStyle(color: theme.subtle, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const <String>[AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_errorMessage != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: TextStyle(color: theme.danger, fontSize: 12),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: <Widget>[
        if (_done)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(
              backgroundColor: theme.primary,
              foregroundColor: theme.onPrimary,
            ),
            child: const Text('Close'),
          )
        else ...<Widget>[
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: theme.subtle)),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: theme.primary,
              foregroundColor: theme.onPrimary,
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
                : const Text('Send reset link'),
          ),
        ],
      ],
    );
  }
}
