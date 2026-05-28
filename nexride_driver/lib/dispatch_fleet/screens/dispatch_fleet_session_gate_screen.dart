import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dispatch_fleet_account_gate.dart';
import '../dispatch_fleet_functions.dart';
import '../dispatch_fleet_routes.dart';

/// One-shot account load after sign-in; routes to signup, pending, rejected, or invites.
class DispatchFleetSessionGateScreen extends StatefulWidget {
  const DispatchFleetSessionGateScreen({super.key});

  @override
  State<DispatchFleetSessionGateScreen> createState() =>
      _DispatchFleetSessionGateScreenState();
}

class _DispatchFleetSessionGateScreenState
    extends State<DispatchFleetSessionGateScreen> {
  final DispatchFleetFunctions _fleet = DispatchFleetFunctions();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadOnce());
  }

  Future<void> _loadOnce() async {
    final user = FirebaseAuth.instance.currentUser;
    if (!mounted) {
      return;
    }
    if (user == null) {
      await Navigator.of(context).pushNamedAndRemoveUntil(
        DispatchFleetRoutes.login,
        (Route<dynamic> route) => false,
      );
      return;
    }

    try {
      final response = await _fleet.dispatchFleetGetMyAccount();
      if (!mounted) {
        return;
      }
      final dest = destinationForFleetAccountResponse(response);
      final route = _routeFor(dest);
      final args = dest == DispatchFleetAccountDestination.pending ||
              dest == DispatchFleetAccountDestination.rejected ||
              dest == DispatchFleetAccountDestination.suspended
          ? response
          : null;
      await Navigator.of(context).pushNamedAndRemoveUntil(
        route,
        (Route<dynamic> route) => false,
        arguments: args,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushNamedAndRemoveUntil(
        DispatchFleetRoutes.pending,
        (Route<dynamic> route) => false,
      );
    }
  }

  String _routeFor(DispatchFleetAccountDestination dest) {
    switch (dest) {
      case DispatchFleetAccountDestination.signup:
        return DispatchFleetRoutes.signup;
      case DispatchFleetAccountDestination.pending:
        return DispatchFleetRoutes.pending;
      case DispatchFleetAccountDestination.rejected:
        return DispatchFleetRoutes.rejected;
      case DispatchFleetAccountDestination.suspended:
        return DispatchFleetRoutes.suspended;
      case DispatchFleetAccountDestination.dashboard:
        return DispatchFleetRoutes.dashboard;
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading your fleet account…'),
          ],
        ),
      ),
    );
  }
}
