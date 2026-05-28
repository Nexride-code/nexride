import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_functions.dart';
import '../dispatch_fleet_routes.dart';

const List<String> _vehicleTypes = <String>['bike', 'car', 'van'];

class DispatchFleetInviteScreen extends StatefulWidget {
  const DispatchFleetInviteScreen({super.key});

  @override
  State<DispatchFleetInviteScreen> createState() =>
      _DispatchFleetInviteScreenState();
}

class _DispatchFleetInviteScreenState extends State<DispatchFleetInviteScreen> {
  final DispatchFleetFunctions _fleet = DispatchFleetFunctions();

  String _vehicleType = 'bike';
  bool _creating = false;
  String? _error;

  String? _inviteCode;
  int? _expiresAtMs;
  String? _businessId;

  String _formatExpiry(int? ms) {
    if (ms == null || ms <= 0) {
      return '—';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${dt.year}-${_two(dt.month)}-${_two(dt.day)} '
        '${_two(dt.hour)}:${_two(dt.minute)}';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  Future<void> _createInvite() async {
    setState(() {
      _creating = true;
      _error = null;
      _inviteCode = null;
      _expiresAtMs = null;
      _businessId = null;
    });
    try {
      final r = await _fleet.businessCreateDriverInvite(
        dispatchVehicleType: _vehicleType,
      );
      if (!mounted) {
        return;
      }
      if (dfSuccess(r['success'])) {
        final code = r['invite_code']?.toString().trim() ??
            r['inviteCode']?.toString().trim() ??
            '';
        final expires = r['expires_at'] ?? r['expiresAt'];
        final businessId = r['business_id']?.toString() ?? r['businessId']?.toString();
        setState(() {
          _inviteCode = code.isEmpty ? null : code;
          _expiresAtMs = expires is num ? expires.toInt() : int.tryParse('$expires');
          _businessId = businessId?.trim();
        });
        return;
      }
      setState(() {
        _error = dfInviteCreateErrorMessage(r['reason']?.toString());
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) {
        return;
      }
      final details = e.details;
      String? reason;
      if (details is Map) {
        reason = details['reason']?.toString();
      }
      setState(() {
        _error = reason != null && reason.isNotEmpty
            ? reason
            : 'invite_create_failed';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'invite_create_failed');
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  String _displayError() {
    final e = _error?.trim() ?? '';
    if (e == 'invite_create_failed') {
      return 'Could not create invite. Check your connection and try again.';
    }
    return dfInviteCreateErrorMessage(e.isEmpty ? null : e);
  }

  Future<void> _copyInviteCode() async {
    final code = _inviteCode?.trim() ?? '';
    if (code.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Invite code copied')),
    );
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).pushNamedAndRemoveUntil(
      DispatchFleetRoutes.root,
      (Route<dynamic> route) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _guardApprovedOnce());
  }

  Future<void> _guardApprovedOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacementNamed(DispatchFleetRoutes.login);
      return;
    }
    try {
      final response = await _fleet.dispatchFleetGetMyAccount();
      if (!mounted) {
        return;
      }
      final dest = destinationForFleetAccountResponse(response);
      if (dest != DispatchFleetAccountDestination.dashboard) {
        final route = switch (dest) {
          DispatchFleetAccountDestination.rejected => DispatchFleetRoutes.rejected,
          DispatchFleetAccountDestination.suspended => DispatchFleetRoutes.suspended,
          DispatchFleetAccountDestination.signup => DispatchFleetRoutes.signup,
          _ => DispatchFleetRoutes.pending,
        };
        await Navigator.of(context).pushReplacementNamed(
          route,
          arguments: response,
        );
      }
    } catch (_) {
      /* invite UI still usable; create will surface errors */
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispatch rider invites'),
        actions: <Widget>[
          TextButton(
            onPressed: _logout,
            child: const Text('Log out'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Fleet Business',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  user.email ?? user.uid,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (_businessId != null && _businessId!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'Business ID: $_businessId',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Dispatch vehicle type',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: ValueKey<String>(_vehicleType),
                  initialValue: _vehicleType,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  items: _vehicleTypes
                      .map(
                        (String v) => DropdownMenuItem<String>(
                          value: v,
                          child: Text(v[0].toUpperCase() + v.substring(1)),
                        ),
                      )
                      .toList(),
                  onChanged: _creating
                      ? null
                      : (String? v) {
                          if (v != null) {
                            setState(() => _vehicleType = v);
                          }
                        },
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _creating ? null : _createInvite,
                  child: _creating
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create Dispatch Rider Invite'),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    _displayError(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_inviteCode != null) ...<Widget>[
                  const SizedBox(height: 28),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            'Invite code',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(
                            _inviteCode!,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.2,
                                ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Expires: ${_formatExpiry(_expiresAtMs)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _copyInviteCode,
                            icon: const Icon(Icons.copy),
                            label: const Text('Copy invite code'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Share this code with your dispatch biker. They redeem it in the '
                  'NexRide Driver app: open Driver Hub → Redeem Fleet Invite.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
