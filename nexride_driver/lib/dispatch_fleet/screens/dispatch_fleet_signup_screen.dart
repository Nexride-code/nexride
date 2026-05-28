import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../dispatch_fleet_functions.dart';
import '../dispatch_fleet_routes.dart';
import '../dispatch_fleet_support.dart';

class DispatchFleetSignupScreen extends StatefulWidget {
  const DispatchFleetSignupScreen({super.key});

  @override
  State<DispatchFleetSignupScreen> createState() =>
      _DispatchFleetSignupScreenState();
}

class _DispatchFleetSignupScreenState extends State<DispatchFleetSignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _businessName = TextEditingController();
  final _ownerName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _regionId = TextEditingController();
  final _cityId = TextEditingController();
  final DispatchFleetFunctions _fleet = DispatchFleetFunctions();

  String _verificationType = 'cac_business';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _businessName.dispose();
    _ownerName.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _phone.dispose();
    _address.dispose();
    _regionId.dispose();
    _cityId.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final email = _email.text.trim();
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: _password.text,
      );
      final uid = cred.user?.uid;
      if (uid == null) {
        throw StateError('auth_failed');
      }

      final registerRes = await _fleet.dispatchFleetRegister(<String, dynamic>{
        'verification_type': _verificationType,
        'verificationType': _verificationType,
        'business_name': _businessName.text.trim(),
        'businessName': _businessName.text.trim(),
        'owner_name': _ownerName.text.trim(),
        'ownerName': _ownerName.text.trim(),
        'contact_email': email,
        'contactEmail': email,
        'phone': _phone.text.trim(),
        'address': _address.text.trim(),
        if (_regionId.text.trim().isNotEmpty) 'region_id': _regionId.text.trim(),
        if (_regionId.text.trim().isNotEmpty) 'regionId': _regionId.text.trim(),
        if (_cityId.text.trim().isNotEmpty) 'city_id': _cityId.text.trim(),
        if (_cityId.text.trim().isNotEmpty) 'cityId': _cityId.text.trim(),
      });

      if (!mounted) {
        return;
      }

      if (!dfSuccess(registerRes['success'])) {
        setState(() {
          _error = dfRegisterErrorMessage(registerRes['reason']?.toString());
        });
        return;
      }

      await Navigator.of(context).pushNamedAndRemoveUntil(
        DispatchFleetRoutes.pending,
        (Route<dynamic> route) => false,
        arguments: <String, dynamic>{
          'success': true,
          'account': <String, dynamic>{
            'business_id': registerRes['business_id'] ?? registerRes['businessId'],
            'business_name': _businessName.text.trim(),
            'verification_type': _verificationType,
            'merchant_status': 'pending_documents',
            'verification_status': 'incomplete',
          },
        },
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (_) {
      setState(() => _error = 'Could not complete signup. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Business signup'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Register your Dispatch Fleet business',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This is for fleet operators managing dispatch bikers — not restaurant or store commerce.',
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _businessName,
                    decoration: const InputDecoration(
                      labelText: 'Fleet business name',
                      border: OutlineInputBorder(),
                    ),
                    validator: (String? v) {
                      if ((v?.trim().length ?? 0) < 2) {
                        return 'Required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _verificationType,
                    decoration: const InputDecoration(
                      labelText: 'Business verification type',
                      border: OutlineInputBorder(),
                    ),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: 'cac_business',
                        child: Text('CAC registered business'),
                      ),
                      DropdownMenuItem(
                        value: 'nin_individual_business',
                        child: Text('NIN individual / sole proprietor'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (String? v) {
                            if (v != null) {
                              setState(() => _verificationType = v);
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _ownerName,
                    decoration: const InputDecoration(
                      labelText: 'Owner name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _email,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    validator: (String? v) {
                      final s = v?.trim() ?? '';
                      if (s.length < 5 || !s.contains('@')) {
                        return 'Enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    validator: (String? v) {
                      if ((v ?? '').length < 6) {
                        return 'At least 6 characters';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirmPassword,
                    decoration: const InputDecoration(
                      labelText: 'Confirm password',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    validator: (String? v) {
                      if (v != _password.text) {
                        return 'Passwords do not match';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _address,
                    decoration: const InputDecoration(
                      labelText: 'Business address',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _regionId,
                    decoration: const InputDecoration(
                      labelText: 'Region (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cityId,
                    decoration: const InputDecoration(
                      labelText: 'City (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Submit application'),
                  ),
                  const SizedBox(height: 12),
                  const DispatchFleetSupportSection(
                    subject: 'Dispatch Fleet registration',
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
