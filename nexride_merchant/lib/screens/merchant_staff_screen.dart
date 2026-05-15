import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_portal_access.dart';
import '../models/merchant_profile.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';

/// Owner-only: invite managers/cashiers or remove staff (callable `merchantPutStaffMember`).
class MerchantStaffScreen extends StatefulWidget {
  const MerchantStaffScreen({super.key});

  @override
  State<MerchantStaffScreen> createState() => _MerchantStaffScreenState();
}

class _MerchantStaffScreenState extends State<MerchantStaffScreen> {
  bool _loading = true;
  String? _error;
  List<String> _uids = <String>[];
  Map<String, String> _roles = <String, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final gw = context.read<MerchantAppState>().gateway;
      final res = await gw.merchantGetMyMerchant();
      if (!nxSuccess(res['success'])) {
        _error = nxMapFailureMessage(
          Map<String, dynamic>.from(res),
          'Could not load staff list.',
        );
      } else {
        final raw = res['merchant'];
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw);
          final su = m['staff_uids'];
          if (su is List) {
            _uids = su.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
          } else {
            _uids = <String>[];
          }
          final sr = m['staff_roles'];
          if (sr is Map) {
            _roles = sr.map((k, v) => MapEntry(k.toString(), v.toString()));
          } else {
            _roles = <String, String>{};
          }
        }
      }
    } catch (e) {
      _error = nxUserFacingMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addStaff() async {
    final state = context.read<MerchantAppState>();
    final m = state.merchant;
    if (!MerchantPortalAccess.canManageStaff(m)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only the store owner can manage staff.')),
      );
      return;
    }
    final emailCtrl = TextEditingController();
    final uidCtrl = TextEditingController();
    String role = 'cashier';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add staff'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Enter the staff member’s NexRide login email, or their Firebase UID if you have it.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: uidCtrl,
                  decoration: const InputDecoration(
                    labelText: 'UID (optional if email set)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey<String>(role),
                  initialValue: role,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'manager', child: Text('Manager — menu, orders, availability')),
                    DropdownMenuItem(value: 'cashier', child: Text('Cashier — orders')),
                  ],
                  onChanged: (v) => setLocal(() => role = v ?? 'cashier'),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final email = emailCtrl.text.trim();
    final uid = uidCtrl.text.trim();
    if (email.isEmpty && uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter an email or UID.')),
      );
      return;
    }
    final payload = <String, dynamic>{
      'role': role,
      if (uid.isNotEmpty) 'staff_uid': uid,
      if (email.isNotEmpty) 'staff_email': email,
    };
    final res = await state.gateway.merchantPutStaffMember(payload);
    if (!mounted) return;
    if (!nxSuccess(res['success'])) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(nxMapFailureMessage(Map<String, dynamic>.from(res), 'Could not add staff.'))),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Staff updated')));
    await _reload();
  }

  Future<void> _remove(String uid) async {
    final state = context.read<MerchantAppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove staff?'),
        content: Text('Remove $uid from this store?'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final res = await state.gateway.merchantPutStaffMember(<String, dynamic>{
      'staff_uid': uid,
      'role': 'remove',
    });
    if (!mounted) return;
    if (!nxSuccess(res['success'])) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(nxMapFailureMessage(Map<String, dynamic>.from(res), 'Could not remove staff.'))),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Staff removed')));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MerchantAppState>(
      builder: (context, state, _) {
        final MerchantProfile? m = state.merchant;
        final ownerUid = FirebaseAuth.instance.currentUser?.uid ?? '';
        if (!MerchantPortalAccess.canManageStaff(m)) {
          return Scaffold(
            appBar: AppBar(title: const Text('Staff')),
            body: const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Only the store owner can manage staff accounts.'),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Staff')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _loading ? null : _addStaff,
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('Add staff'),
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? ListView(
                      padding: const EdgeInsets.all(24),
                      children: <Widget>[
                        NxInlineError(message: _error!),
                        TextButton(onPressed: _reload, child: const Text('Retry')),
                      ],
                    )
                  : RefreshIndicator(
                      onRefresh: _reload,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: <Widget>[
                          Text(
                            'Owner UID: $ownerUid',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          if (_uids.isEmpty)
                            const NxEmptyState(
                              title: 'No staff yet',
                              subtitle: 'Managers can edit the menu and availability. Cashiers handle orders.',
                            )
                          else
                            ..._uids.map(
                              (u) => Card(
                                child: ListTile(
                                  title: Text(u),
                                  subtitle: Text('Role: ${_roles[u] ?? 'cashier'}'),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _remove(u),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
        );
      },
    );
  }
}
