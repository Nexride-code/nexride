import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../merchant_portal_functions.dart';
import 'merchant_entry_screens.dart';

class MerchantOnboardingScreen extends StatefulWidget {
  const MerchantOnboardingScreen({super.key});

  @override
  State<MerchantOnboardingScreen> createState() =>
      _MerchantOnboardingScreenState();
}

class _MerchantOnboardingScreenState extends State<MerchantOnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _businessName = TextEditingController();
  final _ownerName = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();

  String? _regionId;
  String? _cityId;
  String _category = 'Restaurant';
  String _paymentModel = 'subscription';

  List<Map<String, dynamic>> _regions = const <Map<String, dynamic>>[];
  bool _loadingRegions = true;
  String? _regionsError;
  bool _submitting = false;
  String? _submitError;

  static const List<String> _categories = <String>[
    'Restaurant',
    'Grocery & convenience',
    'Pharmacy',
    'Catering',
    'Other',
  ];

  @override
  void initState() {
    super.initState();
    _email.text = FirebaseAuth.instance.currentUser?.email?.trim() ?? '';
    _loadRegions();
  }

  @override
  void dispose() {
    _businessName.dispose();
    _ownerName.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _loadRegions() async {
    setState(() {
      _loadingRegions = true;
      _regionsError = null;
    });
    try {
      final fn = MerchantPortalFunctions();
      final data = await fn.listDeliveryRegions();
      if (data['success'] != true) {
        throw StateError(data['reason']?.toString() ?? 'regions_failed');
      }
      final raw = data['regions'] ?? data['items'];
      final list = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            list.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _regions = list;
        _loadingRegions = false;
        _regionId = null;
        _cityId = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _regionsError = e.toString();
        _loadingRegions = false;
      });
    }
  }

  List<Map<String, dynamic>> _citiesForRegion(String? regionId) {
    if (regionId == null) return const <Map<String, dynamic>>[];
    Map<String, dynamic>? region;
    for (final r in _regions) {
      if (_str(r['region_id']) == regionId) {
        region = r;
        break;
      }
    }
    if (region == null) return const <Map<String, dynamic>>[];
    final citiesRaw = region['cities'];
    if (citiesRaw is! List) return const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final c in citiesRaw) {
      if (c is Map) {
        final m = c.map((k, v) => MapEntry(k.toString(), v));
        if (m['supports_merchant'] == false) continue;
        out.add(m);
      }
    }
    out.sort(
      (a, b) => _str(a['display_name']).compareTo(_str(b['display_name'])),
    );
    return out;
  }

  String _str(dynamic v) => v?.toString().trim() ?? '';

  String? _validRegionValue() {
    if (_regionId == null || _regionId!.isEmpty) return null;
    for (final r in _regions) {
      if (_str(r['region_id']) == _regionId) return _regionId;
    }
    return null;
  }

  String? _validCityValue() {
    if (_cityId == null || _cityId!.isEmpty) return null;
    for (final c in _citiesForRegion(_regionId)) {
      if (_str(c['city_id']) == _cityId) return _cityId;
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_regionId == null || _cityId == null) {
      setState(() => _submitError = 'Select region and city.');
      return;
    }
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final fn = MerchantPortalFunctions();
      final res = await fn.merchantRegister(<String, dynamic>{
        'business_name': _businessName.text.trim(),
        'owner_name': _ownerName.text.trim(),
        'phone': _phone.text.trim(),
        'contact_email': _email.text.trim().toLowerCase(),
        'category': _category,
        'region_id': _regionId,
        'city_id': _cityId,
        'address': _address.text.trim(),
        'payment_model': _paymentModel,
      });
      if (res['success'] != true) {
        throw StateError(res['reason']?.toString() ?? 'register_failed');
      }
      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => const MerchantSessionGateScreen(),
        ),
        (_) => false,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _submitError = e.toString());
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Merchant application'),
        actions: <Widget>[
          TextButton(
            onPressed: () => FirebaseAuth.instance.signOut(),
            child: const Text('Log out'),
          ),
        ],
      ),
      body: _loadingRegions
          ? const Center(child: CircularProgressIndicator())
          : _regionsError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(_regionsError!),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _loadRegions,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _regions.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No enabled rollout regions are available yet. '
                          'Ask NexRide ops to enable delivery regions.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              'Business details',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Regions and cities come from NexRide rollout '
                              'configuration (no hardcoded list).',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 20),
                            TextFormField(
                              controller: _businessName,
                              decoration: const InputDecoration(
                                labelText: 'Business name',
                                border: OutlineInputBorder(),
                              ),
                              validator: (v) {
                                if ((v ?? '').trim().length < 2) {
                                  return 'Required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _ownerName,
                              decoration: const InputDecoration(
                                labelText: 'Owner name',
                                border: OutlineInputBorder(),
                              ),
                              validator: (v) {
                                if ((v ?? '').trim().length < 2) {
                                  return 'Required';
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
                              validator: (v) {
                                if ((v ?? '').trim().length < 6) {
                                  return 'Required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _email,
                              decoration: const InputDecoration(
                                labelText: 'Contact email',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.emailAddress,
                              validator: (v) {
                                final s = (v ?? '').trim();
                                if (s.length < 5 || !s.contains('@')) {
                                  return 'Valid email required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Business category',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _categories
                                  .map(
                                    (c) => FilterChip(
                                      label: Text(c),
                                      selected: _category == c,
                                      onSelected: (_) =>
                                          setState(() => _category = c),
                                    ),
                                  )
                                  .toList(),
                            ),
                            const SizedBox(height: 12),
                            InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Region / state',
                                border: OutlineInputBorder(),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  hint: const Text('Select region'),
                                  value: _validRegionValue(),
                                  items: _regions
                                      .map(
                                        (r) => DropdownMenuItem<String>(
                                          value: _str(r['region_id']),
                                          child: Text(
                                            '${_str(r['state'])} (${_str(r['region_id'])})',
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (rid) {
                                    setState(() {
                                      _regionId = rid;
                                      _cityId = null;
                                    });
                                  },
                                ),
                              ),
                            ),
                            if (_regionId == null || _regionId!.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 12, top: 4),
                                child: Text(
                                  'Pick a region',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 12),
                            InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'City',
                                border: OutlineInputBorder(),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  hint: const Text('Select city'),
                                  value: _validCityValue(),
                                  items: _citiesForRegion(_regionId)
                                      .map(
                                        (c) => DropdownMenuItem<String>(
                                          value: _str(c['city_id']),
                                          child: Text(_str(c['display_name'])),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (cid) =>
                                      setState(() => _cityId = cid),
                                ),
                              ),
                            ),
                            if (_regionId != null &&
                                _regionId!.isNotEmpty &&
                                (_cityId == null || _cityId!.isEmpty))
                              Padding(
                                padding: const EdgeInsets.only(left: 12, top: 4),
                                child: Text(
                                  'Pick a city',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _address,
                              decoration: const InputDecoration(
                                labelText: 'Business address',
                                border: OutlineInputBorder(),
                              ),
                              maxLines: 2,
                              validator: (v) {
                                if ((v ?? '').trim().length < 4) {
                                  return 'Address required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Payment model',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Subscription: ₦25,000/month · 0% commission · 100% withdrawal',
                              style: TextStyle(fontSize: 13),
                            ),
                            const Text(
                              'Commission: 10% per completed order · 90% withdrawal',
                              style: TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: const <ButtonSegment<String>>[
                                ButtonSegment<String>(
                                  value: 'subscription',
                                  label: Text('Subscription'),
                                ),
                                ButtonSegment<String>(
                                  value: 'commission',
                                  label: Text('Commission'),
                                ),
                              ],
                              selected: <String>{_paymentModel},
                              onSelectionChanged: (Set<String> s) {
                                if (s.isNotEmpty) {
                                  setState(() => _paymentModel = s.first);
                                }
                              },
                            ),
                            if (_submitError != null) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                _submitError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: _submitting ? null : _submit,
                              child: _submitting
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Submit application'),
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
