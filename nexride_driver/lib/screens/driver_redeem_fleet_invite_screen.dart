import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import '../services/fleet_business_functions.dart';
import '../support/realtime_database_error_support.dart';

class DriverRedeemFleetInviteScreen extends StatefulWidget {
  const DriverRedeemFleetInviteScreen({
    super.key,
    required this.driverId,
  });

  final String driverId;

  @override
  State<DriverRedeemFleetInviteScreen> createState() =>
      _DriverRedeemFleetInviteScreenState();
}

class _DriverRedeemFleetInviteScreenState
    extends State<DriverRedeemFleetInviteScreen> {
  final FleetBusinessFunctions _fleet = FleetBusinessFunctions();
  final TextEditingController _codeController = TextEditingController();
  final rtdb.DatabaseReference _root = rtdb.FirebaseDatabase.instance.ref();

  bool _redeeming = false;
  String? _error;
  bool _linked = false;

  String? _ownershipMode;
  String? _dispatchVehicleType;
  String? _businessId;
  String? _businessName;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _refreshProfileOnce() async {
    final snap = await runOptionalRealtimeDatabaseRead<rtdb.DataSnapshot>(
      source: 'driver_redeem_fleet_invite.profile',
      path: 'drivers/${widget.driverId}',
      action: () => _root.child('drivers/${widget.driverId}').get(),
    );
    if (!mounted || snap?.value is! Map) {
      return;
    }
    final profile = Map<String, dynamic>.from(snap!.value as Map);
    setState(() {
      _ownershipMode =
          profile['ownership_mode']?.toString() ?? profile['ownershipMode']?.toString();
      _dispatchVehicleType = profile['dispatch_vehicle_type']?.toString() ??
          profile['dispatchVehicleType']?.toString();
      _businessId =
          profile['business_id']?.toString() ?? profile['businessId']?.toString();
      _businessName = profile['business_name']?.toString() ??
          profile['businessName']?.toString();
    });
  }

  Future<void> _redeem() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter an invite code.');
      return;
    }

    setState(() {
      _redeeming = true;
      _error = null;
      _linked = false;
    });

    try {
      final r = await _fleet.driverRedeemBusinessInvite(inviteCode: code);
      if (!mounted) {
        return;
      }

      final success = r['success'] == true ||
          r['success']?.toString().toLowerCase() == 'true';
      if (!success) {
        setState(() {
          _error = fleetRedeemErrorMessage(r['reason']?.toString());
        });
        return;
      }

      setState(() {
        _linked = true;
        _ownershipMode = r['ownership_mode']?.toString() ??
            r['ownershipMode']?.toString() ??
            'business_managed';
        _dispatchVehicleType = r['dispatch_vehicle_type']?.toString() ??
            r['dispatchVehicleType']?.toString();
        _businessId =
            r['business_id']?.toString() ?? r['businessId']?.toString();
        _businessName =
            r['business_name']?.toString() ?? r['businessName']?.toString();
      });

      await _refreshProfileOnce();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Could not redeem invite. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _redeeming = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = FirebaseAuth.instance.currentUser != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Redeem Fleet Invite'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          if (!signedIn)
            const Text(
              'You must be signed in to redeem a fleet invite.',
              style: TextStyle(color: Colors.red),
            ),
          Text(
            'Enter the invite code from your Dispatch Fleet business owner.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeController,
            enabled: !_redeeming && signedIn,
            decoration: const InputDecoration(
              labelText: 'Invite code',
              hintText: 'NXR-…',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _redeeming || !signedIn ? null : _redeem,
            child: _redeeming
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Redeem invite'),
          ),
          if (_linked) ...<Widget>[
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Linked to business successfully',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.green.shade800,
                          ),
                    ),
                    const SizedBox(height: 12),
                    _infoRow('Ownership', _ownershipMode ?? 'business_managed'),
                    _infoRow('Vehicle type', _dispatchVehicleType ?? '—'),
                    if (_businessId != null && _businessId!.isNotEmpty)
                      _infoRow('Business ID', _businessId!),
                    if (_businessName != null && _businessName!.isNotEmpty)
                      _infoRow('Business name', _businessName!),
                    const SizedBox(height: 12),
                    Text(
                      'Your delivery earnings are managed by your business. '
                      'Withdrawals are handled by your business owner.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontStyle: FontStyle.italic,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
