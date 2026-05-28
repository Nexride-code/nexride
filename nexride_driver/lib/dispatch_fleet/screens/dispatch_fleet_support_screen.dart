import 'package:flutter/material.dart';

import '../dispatch_fleet_support.dart';

class DispatchFleetSupportScreen extends StatelessWidget {
  const DispatchFleetSupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Support'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: const <Widget>[
                Text(
                  'Need help with Dispatch Fleet onboarding, approvals, or biker invites?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, height: 1.5),
                ),
                SizedBox(height: 24),
                DispatchFleetSupportSection(
                  subject: 'Dispatch Fleet support',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
