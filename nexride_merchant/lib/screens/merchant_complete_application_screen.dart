import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

/// For signed-in accounts that have no `merchants` row yet (callable returned `not_found`).
class MerchantCompleteApplicationScreen extends StatefulWidget {
  const MerchantCompleteApplicationScreen({super.key});

  @override
  State<MerchantCompleteApplicationScreen> createState() => _MerchantCompleteApplicationScreenState();
}

class _MerchantCompleteApplicationScreenState extends State<MerchantCompleteApplicationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _businessName = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _ownerName = TextEditingController();
  final _registration = TextEditingController();
  String _businessType = 'restaurant';
  bool _busy = false;
  String? _error;

  static const List<DropdownMenuItem<String>> _typeItems = <DropdownMenuItem<String>>[
    DropdownMenuItem(value: 'restaurant', child: Text('Restaurant')),
    DropdownMenuItem(value: 'grocery', child: Text('Grocery')),
    DropdownMenuItem(value: 'mart', child: Text('Mart / convenience')),
    DropdownMenuItem(value: 'pharmacy', child: Text('Pharmacy')),
    DropdownMenuItem(value: 'other', child: Text('Other')),
  ];

  @override
  void dispose() {
    _businessName.dispose();
    _phone.dispose();
    _address.dispose();
    _ownerName.dispose();
    _registration.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final email = FirebaseAuth.instance.currentUser?.email?.trim();
    if (email == null || email.isEmpty) {
      setState(() => _error = 'You must be signed in to submit an application.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final gw = context.read<MerchantAppState>().gateway;
    try {
      final reg = await gw.merchantRegister(<String, dynamic>{
        'business_name': _businessName.text.trim(),
        'contact_email': email,
        'phone': _phone.text.trim(),
        'address': _address.text.trim(),
        'owner_name': _ownerName.text.trim(),
        'business_type': _businessType,
        if (_registration.text.trim().isNotEmpty)
          'business_registration_number': _registration.text.trim(),
        'payment_model': 'subscription',
      });
      if (!mounted) return;
      if (reg['success'] != true) {
        setState(() {
          _error = nxMapFailureMessage(
            Map<String, dynamic>.from(reg),
            'Registration could not be completed.',
          );
        });
        return;
      }
      await context.read<MerchantAppState>().refreshMerchant();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = nxUserFacingMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = FirebaseAuth.instance.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Merchant application')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('Signed in as $email', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _businessName,
                    decoration: const InputDecoration(labelText: 'Business / store name'),
                    validator: (v) =>
                        (v == null || v.trim().length < 2) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey<String>(_businessType),
                    initialValue: _businessType,
                    decoration: const InputDecoration(
                      labelText: 'Business type',
                      border: OutlineInputBorder(),
                    ),
                    items: _typeItems,
                    onChanged: _busy
                        ? null
                        : (v) {
                            if (v != null) setState(() => _businessType = v);
                          },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone number'),
                    validator: (v) =>
                        (v == null || v.trim().length < 6) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _address,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Store address'),
                    validator: (v) =>
                        (v == null || v.trim().length < 4) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ownerName,
                    decoration: const InputDecoration(labelText: 'Owner name'),
                    validator: (v) =>
                        (v == null || v.trim().length < 2) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _registration,
                    decoration: const InputDecoration(
                      labelText: 'Business registration / CAC (optional)',
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit for review'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
