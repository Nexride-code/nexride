import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/merchant_profile.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

/// Approved merchants: persist storefront availability via [merchantUpdateAvailability].
class MerchantAvailabilityScreen extends StatefulWidget {
  const MerchantAvailabilityScreen({super.key});

  @override
  State<MerchantAvailabilityScreen> createState() => _MerchantAvailabilityScreenState();
}

class _MerchantAvailabilityScreenState extends State<MerchantAvailabilityScreen> {
  bool _busy = false;
  late String _mode; // open | closed | paused
  final _reason = TextEditingController();

  static String _deriveMode(MerchantProfile? m) {
    if (m == null) return 'closed';
    final a = (m.availabilityStatus ?? '').toLowerCase();
    if (a == 'open' || a == 'closed' || a == 'paused') {
      return a;
    }
    if (m.isOpen && m.acceptingOrders) return 'open';
    if (m.isOpen && !m.acceptingOrders) return 'paused';
    return 'closed';
  }

  @override
  void initState() {
    super.initState();
    final m = context.read<MerchantAppState>().merchant;
    _mode = _deriveMode(m);
    _reason.text = m?.closedReason ?? '';
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await context.read<MerchantAppState>().gateway.merchantUpdateAvailability(<String, dynamic>{
        'availability_status': _mode,
        if (_reason.text.trim().isNotEmpty) 'closed_reason': _reason.text.trim(),
      });
      if (!mounted) return;
      if (res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Availability could not be updated.',
              ),
            ),
          ),
        );
        return;
      }
      await context.read<MerchantAppState>().refreshMerchant();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Store availability saved')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(nxUserFacingMessage(e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final approved = context.watch<MerchantAppState>().isApproved;
    return Scaffold(
      appBar: AppBar(title: const Text('Store availability')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (!approved)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const ListTile(
                title: Text('Not available yet'),
                subtitle: Text(
                  'NexRide must approve your store before you can go live for riders.',
                ),
              ),
            ),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(_mode),
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: 'Storefront mode',
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(
                value: 'open',
                child: Text('Open — accepting orders'),
              ),
              DropdownMenuItem(
                value: 'paused',
                child: Text('Paused — not accepting new orders'),
              ),
              DropdownMenuItem(
                value: 'closed',
                child: Text('Closed'),
              ),
            ],
            onChanged: !approved || _busy
                ? null
                : (v) {
                    if (v != null) setState(() => _mode = v);
                  },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Message for customers (optional)',
              hintText: 'e.g. Closed for renovation — back Friday',
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (!approved || _busy) ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save to server'),
          ),
        ],
      ),
    );
  }
}
