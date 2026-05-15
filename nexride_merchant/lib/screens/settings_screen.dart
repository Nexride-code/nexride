import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_portal_access.dart';
import '../state/merchant_app_state.dart';
import 'merchant_staff_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser;
    final merchant = context.watch<MerchantAppState>().merchant;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: const Text('Signed in as'),
            subtitle: Text(u?.email ?? u?.uid ?? '—'),
          ),
          if (MerchantPortalAccess.canManageStaff(merchant))
            ListTile(
              leading: const Icon(Icons.group_outlined),
              title: const Text('Staff accounts'),
              subtitle: const Text('Add managers or cashiers by email'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MerchantStaffScreen()),
              ),
            ),
          ListTile(
            title: const Text('Sign out'),
            onTap: () => FirebaseAuth.instance.signOut(),
          ),
          const ListTile(
            title: Text('Legal'),
            subtitle: Text('NexRide merchant terms are governed by your store agreement and admin policies.'),
          ),
        ],
      ),
    );
  }
}
