/// Account Security screen for admin / support portals.
///
/// Read-only summary of the operator's session security posture:
///
///   * Email + UID
///   * Last sign-in time and account creation time (Firebase Auth metadata)
///   * Password last changed (mirror from RTDB `/account_security/{uid}`)
///   * MFA enrollment placeholder (not yet rolled out — see
///     `docs/admin_password_management.md`)
///   * Filtered, safe view of active custom claims (admin / support /
///     role / temporaryPassword)
///
/// Action buttons: Change password, Refresh, Sign out.
library;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'portal_password_service.dart';
import 'portal_security_theme.dart';

class PortalAccountSecurityScreen extends StatefulWidget {
  const PortalAccountSecurityScreen({
    required this.theme,
    required this.changePasswordRoute,
    required this.loginRoute,
    super.key,
    this.passwordService,
    this.heading = 'Account security',
  });

  final PortalSecurityTheme theme;
  final String changePasswordRoute;
  final String loginRoute;
  final PortalPasswordService? passwordService;
  final String heading;

  @override
  State<PortalAccountSecurityScreen> createState() =>
      _PortalAccountSecurityScreenState();
}

class _PortalAccountSecurityScreenState
    extends State<PortalAccountSecurityScreen> {
  late final PortalPasswordService _service;
  late Future<PortalAccountSecurityInfo> _infoFuture;

  @override
  void initState() {
    super.initState();
    _service = widget.passwordService ?? PortalPasswordService();
    _infoFuture = _service.loadAccountSecurity();
  }

  void _refresh() {
    setState(() {
      _infoFuture = _service.loadAccountSecurity();
    });
  }

  Future<void> _signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // ignore — we navigate regardless
    }
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      widget.loginRoute,
      (Route<dynamic> _) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Scaffold(
      backgroundColor: theme.canvas,
      appBar: AppBar(
        title: Text(widget.heading),
        backgroundColor: theme.appBarBackground,
        foregroundColor: theme.appBarForeground,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: FutureBuilder<PortalAccountSecurityInfo>(
                future: _infoFuture,
                builder: (
                  BuildContext context,
                  AsyncSnapshot<PortalAccountSecurityInfo> snapshot,
                ) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 80),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return _ErrorCard(
                      theme: theme,
                      message: snapshot.error.toString(),
                      onRetry: _refresh,
                    );
                  }
                  final info = snapshot.data;
                  if (info == null) {
                    return _ErrorCard(
                      theme: theme,
                      message: 'No active session.',
                      onRetry: _refresh,
                    );
                  }
                  return _SecurityBody(
                    theme: theme,
                    info: info,
                    onChangePassword: () => Navigator.of(context)
                        .pushNamed(widget.changePasswordRoute),
                    onRefresh: _refresh,
                    onSignOut: _signOut,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecurityBody extends StatelessWidget {
  const _SecurityBody({
    required this.theme,
    required this.info,
    required this.onChangePassword,
    required this.onRefresh,
    required this.onSignOut,
  });

  final PortalSecurityTheme theme;
  final PortalAccountSecurityInfo info;
  final VoidCallback onChangePassword;
  final VoidCallback onRefresh;
  final VoidCallback onSignOut;

  String _formatDate(DateTime? value) {
    if (value == null) return '—';
    return value.toLocal().toString();
  }

  String _formatClaims(Map<String, dynamic> claims) {
    if (claims.isEmpty) return '—';
    final entries = claims.entries.toList()
      ..sort((MapEntry<String, dynamic> a, MapEntry<String, dynamic> b) =>
          a.key.compareTo(b.key));
    return entries.map((MapEntry<String, dynamic> e) => '${e.key}: ${e.value}').join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final mfaText = info.mfaEnabled
        ? 'Enabled'
        : 'Not enrolled — coming soon. See docs/admin_password_management.md.';
    final pwChangedText = info.passwordChangedAt != null
        ? _formatDate(info.passwordChangedAt)
        : 'Not recorded yet (rotate your password to start tracking).';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (info.temporaryPassword)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.warningBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.warningBorder),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.warning_amber_rounded,
                        color: theme.warningForeground, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This account is using a temporary password. Use the '
                        '"Change password" button below to rotate it.',
                        style: TextStyle(
                          color: theme.warningForeground,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _Row(theme: theme, label: 'Email', value: info.email.isEmpty ? '—' : info.email),
          _Row(theme: theme, label: 'UID', value: info.uid, monospace: true),
          _Row(theme: theme, label: 'Last sign-in', value: _formatDate(info.lastSignInTime)),
          _Row(theme: theme, label: 'Account created', value: _formatDate(info.creationTime)),
          _Row(theme: theme, label: 'Password last changed', value: pwChangedText),
          _Row(theme: theme, label: 'MFA', value: mfaText),
          _Row(
            theme: theme,
            label: 'Active claims',
            value: _formatClaims(info.claims),
            monospace: true,
            multiline: true,
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.start,
            children: <Widget>[
              FilledButton.icon(
                onPressed: onChangePassword,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.primary,
                  foregroundColor: theme.onPrimary,
                ),
                icon: const Icon(Icons.lock_reset_rounded, size: 18),
                label: const Text('Change password'),
              ),
              OutlinedButton.icon(
                onPressed: onRefresh,
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.primary,
                  side: BorderSide(color: theme.primary),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh'),
              ),
              OutlinedButton.icon(
                onPressed: onSignOut,
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.danger,
                  side: BorderSide(color: theme.danger),
                ),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Sign out'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Need to add another admin? See docs/admin_access.md.',
            style: TextStyle(
              color: theme.subtle,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.theme,
    required this.label,
    required this.value,
    this.monospace = false,
    this.multiline = false,
  });

  final PortalSecurityTheme theme;
  final String label;
  final String value;
  final bool monospace;
  final bool multiline;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.border, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.only(bottom: 8),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final isNarrow = constraints.maxWidth < 480;
            final children = <Widget>[
              SizedBox(
                width: isNarrow ? double.infinity : 200,
                child: Text(
                  label,
                  style: TextStyle(
                    color: theme.subtle,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (!isNarrow) const SizedBox(width: 16),
              if (isNarrow) const SizedBox(height: 4),
              Expanded(
                child: SelectableText(
                  value,
                  maxLines: multiline ? null : 2,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    fontFamily: monospace
                        ? 'ui-monospace, SFMono-Regular, Menlo, monospace'
                        : null,
                  ),
                ),
              ),
            ];
            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            );
          },
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.theme,
    required this.message,
    required this.onRetry,
  });

  final PortalSecurityTheme theme;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.dangerBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dangerBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Could not load account security',
            style: TextStyle(
              color: theme.danger,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(message, style: TextStyle(color: theme.danger, fontSize: 13)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.danger,
              side: BorderSide(color: theme.danger),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
