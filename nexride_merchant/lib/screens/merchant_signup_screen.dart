import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

/// Self-serve merchant registration: Firebase Auth account + Firestore merchant row (pending).
class MerchantSignupScreen extends StatefulWidget {
  const MerchantSignupScreen({super.key});

  @override
  State<MerchantSignupScreen> createState() => _MerchantSignupScreenState();
}

class _MerchantSignupScreenState extends State<MerchantSignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
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
    DropdownMenuItem(value: 'grocery_mart', child: Text('Grocery / Mart')),
    DropdownMenuItem(value: 'pharmacy', child: Text('Pharmacy')),
    DropdownMenuItem(value: 'other', child: Text('Other')),
  ];

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _businessName.dispose();
    _phone.dispose();
    _address.dispose();
    _ownerName.dispose();
    _registration.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final gw = context.read<MerchantAppState>().gateway;
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      final reg = await gw.merchantRegister(<String, dynamic>{
        'business_name': _businessName.text.trim(),
        'contact_email': _email.text.trim(),
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
        await FirebaseAuth.instance.signOut();
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
      Navigator.of(context).popUntil((r) => r.isFirst);
    } on FirebaseAuthException catch (e) {
      setState(() => _error = nxUserFacingMessage(e));
    } catch (e) {
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        setState(() => _error = nxUserFacingMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create merchant account')),
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
                  Text(
                    'NexRide Merchant',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Submit your store for NexRide review. You can sign in while pending approval.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email (login)'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password (min 6 characters)'),
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'At least 6 characters' : null,
                  ),
                  const SizedBox(height: 12),
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
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).pop();
                          },
                    child: const Text('Back to sign in'),
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
