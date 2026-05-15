import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_portal_access.dart';
import '../services/merchant_connectivity.dart';
import '../services/merchant_fcm_service.dart';
import '../state/merchant_app_state.dart';
import 'dashboard_screen.dart';
import 'earnings_withdrawals_screen.dart';
import 'menu_categories_screen.dart';
import 'merchant_staff_screen.dart';
import 'orders_screen.dart';
import 'settings_screen.dart';
import 'subscription_billing_screen.dart';
import 'support_tickets_screen.dart';
import 'wallet_screen.dart';

class MerchantShellScreen extends StatefulWidget {
  const MerchantShellScreen({super.key});

  @override
  State<MerchantShellScreen> createState() => _MerchantShellScreenState();
}

class _MerchantShellScreenState extends State<MerchantShellScreen> {
  int _index = 0;
  Timer? _heartbeat;
  late final String _portalSessionId =
      '${DateTime.now().millisecondsSinceEpoch}_${FirebaseAuth.instance.currentUser?.uid ?? 'anon'}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final s = context.read<MerchantAppState>();
      await MerchantFcmService.instance.init(s.gateway);
      if (s.merchant != null && s.isApproved) {
        try {
          await s.gateway.merchantPortalHeartbeat(<String, dynamic>{
            'session_id': _portalSessionId,
            'device_label': 'nexride_merchant',
          });
        } catch (_) {}
      }
      _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) async {
        if (!mounted) return;
        final st = context.read<MerchantAppState>();
        if (st.merchant == null || !st.isApproved) return;
        try {
          await st.gateway.merchantPortalHeartbeat(<String, dynamic>{
            'session_id': _portalSessionId,
            'device_label': 'nexride_merchant',
          });
        } catch (_) {}
      });
    });
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    super.dispose();
  }

  static const List<Widget> _tabs = <Widget>[
    DashboardScreen(),
    OrdersScreen(),
    MenuCategoriesScreen(),
    SupportTicketsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final online = context.watch<MerchantConnectivity>().online;
    final merchant = context.watch<MerchantAppState>().merchant;
    final canBill = MerchantPortalAccess.canManageBilling(merchant);
    final canLedger = MerchantPortalAccess.canViewWalletLedger(merchant);

    return Scaffold(
      appBar: AppBar(
        title: Text(<String>['Home', 'Orders', 'Menu', 'Support'][_index]),
        actions: <Widget>[
          if (canLedger)
            IconButton(
              tooltip: 'Wallet',
              icon: const Icon(Icons.account_balance_wallet_outlined),
              onPressed: !online
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const WalletScreen()),
                      ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'sub':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SubscriptionBillingScreen(),
                    ),
                  );
                case 'earn':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const EarningsWithdrawalsScreen(),
                    ),
                  );
                case 'staff':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MerchantStaffScreen(),
                    ),
                  );
                case 'set':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  );
                case 'out':
                  FirebaseAuth.instance.signOut();
              }
            },
            itemBuilder: (BuildContext context) {
              final out = <PopupMenuEntry<String>>[];
              if (canBill) {
                out.addAll(const <PopupMenuEntry<String>>[
                  PopupMenuItem(value: 'sub', child: Text('Subscription & billing')),
                  PopupMenuItem(value: 'earn', child: Text('Earnings & withdrawals')),
                ]);
              }
              if (MerchantPortalAccess.canManageStaff(merchant)) {
                out.add(const PopupMenuItem(value: 'staff', child: Text('Staff')));
              }
              out.addAll(const <PopupMenuEntry<String>>[
                PopupMenuItem(value: 'set', child: Text('Settings')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'out', child: Text('Sign out')),
              ]);
              return out;
            },
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!online)
            MaterialBanner(
              content: const Text('You appear to be offline. Some actions are disabled until you reconnect.'),
              leading: const Icon(Icons.wifi_off),
              actions: <Widget>[
                TextButton(
                  onPressed: () => setState(() {}),
                  child: const Text('OK'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(index: _index, children: _tabs),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const <NavigationDestination>[
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Orders'),
          NavigationDestination(icon: Icon(Icons.restaurant_menu_outlined), label: 'Menu'),
          NavigationDestination(icon: Icon(Icons.support_agent_outlined), label: 'Support'),
        ],
      ),
    );
  }
}
