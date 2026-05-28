import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../support/driver_profile_support.dart';
import 'driver_redeem_fleet_invite_screen.dart';

/// Persists the ownership choice to the driver profile. Injectable for tests.
typedef OwnershipUpdatePersister = Future<void> Function(
  Map<String, Object?> update,
);

/// Ownership onboarding for new bike/van dispatch drivers.
///
/// Lets the driver pick how they operate:
/// - Independent dispatch rider (ownership_mode = individual)
/// - Business/Fleet invite (opens the existing redeem screen)
///
/// This screen does not touch wallet, dispatch matching, or verification
/// gates. It only records the ownership choice and marks the step complete.
class DriverOnboardingOwnershipScreen extends StatefulWidget {
  const DriverOnboardingOwnershipScreen({
    super.key,
    required this.driverId,
    required this.serviceType,
    required this.onCompleted,
    this.persistOwnershipUpdate,
    this.fleetInviteScreenBuilder,
  });

  final String driverId;
  final String serviceType;

  /// Invoked after the ownership choice resolves so the host can re-read the
  /// profile (keyed read) and continue routing.
  final VoidCallback onCompleted;

  /// Defaults to a keyed RTDB update on `drivers/{driverId}`.
  final OwnershipUpdatePersister? persistOwnershipUpdate;

  /// Defaults to the existing [DriverRedeemFleetInviteScreen].
  final WidgetBuilder? fleetInviteScreenBuilder;

  @override
  State<DriverOnboardingOwnershipScreen> createState() =>
      _DriverOnboardingOwnershipScreenState();
}

class _DriverOnboardingOwnershipScreenState
    extends State<DriverOnboardingOwnershipScreen> {
  bool _busy = false;
  String? _error;

  String get _vehicleLabel {
    switch (normalizeDriverServiceType(widget.serviceType)) {
      case kServiceTypeBikeDispatch:
        return 'bike';
      case kServiceTypeVanDispatch:
        return 'van';
      default:
        return 'dispatch';
    }
  }

  Future<void> _defaultPersist(Map<String, Object?> update) async {
    final ref = FirebaseDatabase.instance
        .ref()
        .child('drivers/${widget.driverId}');
    await ref.update(<String, Object?>{
      ...update,
      'updated_at': ServerValue.timestamp,
    });
  }

  Future<void> _chooseIndependent() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final persist = widget.persistOwnershipUpdate ?? _defaultPersist;
      await persist(independentDispatchOwnershipUpdate());
      if (!mounted) {
        return;
      }
      widget.onCompleted();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not save your choice. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _chooseFleetInvite() async {
    if (_busy) {
      return;
    }
    final builder = widget.fleetInviteScreenBuilder ??
        (BuildContext _) =>
            DriverRedeemFleetInviteScreen(driverId: widget.driverId);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: builder),
    );
    if (!mounted) {
      return;
    }
    // Re-read the profile via the host; if the invite was redeemed the driver
    // is now business_managed and the gate clears, otherwise they stay here.
    widget.onCompleted();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kDriverCream,
      appBar: AppBar(
        title: const Text('Set up your dispatch account'),
        backgroundColor: kDriverGold,
        foregroundColor: Colors.black,
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: kDriverDark,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'How do you operate?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Choose how your $_vehicleLabel dispatch account is run. '
                    'You can change this later with help from support.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.76),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _OwnershipCard(
              icon: Icons.person_outline,
              title: 'Independent dispatch rider',
              subtitle:
                  'You run your own deliveries and manage your own earnings '
                  'and withdrawals.',
              enabled: !_busy,
              onTap: _chooseIndependent,
            ),
            const SizedBox(height: 12),
            _OwnershipCard(
              icon: Icons.apartment_outlined,
              title: 'I have a business/fleet invite',
              subtitle:
                  'Join a Dispatch Fleet business with an invite code. Your '
                  'earnings are managed by the business.',
              enabled: !_busy,
              onTap: _chooseFleetInvite,
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_busy) ...<Widget>[
              const SizedBox(height: 24),
              const Center(
                child: CircularProgressIndicator(color: kDriverGold),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OwnershipCard extends StatelessWidget {
  const _OwnershipCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: kDriverGold.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: kDriverDark),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.62),
                        height: 1.4,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                color: Colors.black.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
