import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/merchant_profile.dart';
import '../services/merchant_media_service.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

class StoreProfileScreen extends StatefulWidget {
  const StoreProfileScreen({super.key});

  @override
  State<StoreProfileScreen> createState() => _StoreProfileScreenState();
}

class _StoreProfileScreenState extends State<StoreProfileScreen> {
  final _business = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _owner = TextEditingController();
  final _category = TextEditingController();
  final _address = TextEditingController();
  final _region = TextEditingController();
  final _city = TextEditingController();
  final _registration = TextEditingController();
  final _description = TextEditingController();
  final _openingHours = TextEditingController();
  String _businessType = 'restaurant';
  bool _busy = false;
  bool _seeded = false;
  String? _logoUrl;
  String? _bannerUrl;

  static const List<DropdownMenuItem<String>> _typeItems = <DropdownMenuItem<String>>[
    DropdownMenuItem(value: 'restaurant', child: Text('Restaurant')),
    DropdownMenuItem(value: 'grocery_mart', child: Text('Grocery / Mart')),
    DropdownMenuItem(value: 'grocery', child: Text('Grocery only')),
    DropdownMenuItem(value: 'mart', child: Text('Mart / convenience')),
    DropdownMenuItem(value: 'pharmacy', child: Text('Pharmacy')),
    DropdownMenuItem(value: 'other', child: Text('Other')),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    final m = context.read<MerchantAppState>().merchant;
    if (m != null) {
      _apply(m);
      _seeded = true;
    }
  }

  void _apply(MerchantProfile m) {
    _business.text = m.businessName;
    _email.text = m.contactEmail ?? '';
    _phone.text = m.phone ?? '';
    _owner.text = m.ownerName ?? '';
    _category.text = m.category ?? '';
    _address.text = m.address ?? '';
    _region.text = '';
    _city.text = '';
    _registration.text = m.businessRegistrationNumber ?? '';
    _description.text = m.storeDescription ?? '';
    _openingHours.text = m.openingHours ?? '';
    final t = (m.businessType ?? 'restaurant').toLowerCase();
    _businessType = const {
      'restaurant',
      'grocery',
      'mart',
      'grocery_mart',
      'pharmacy',
      'other',
    }.contains(t)
        ? t
        : 'other';
    _logoUrl = m.storeLogoUrl;
    _bannerUrl = m.storeBannerUrl;
  }

  @override
  void dispose() {
    _business.dispose();
    _email.dispose();
    _phone.dispose();
    _owner.dispose();
    _category.dispose();
    _address.dispose();
    _region.dispose();
    _city.dispose();
    _registration.dispose();
    _description.dispose();
    _openingHours.dispose();
    super.dispose();
  }

  Future<void> _uploadBrand(String kind) async {
    final state = context.read<MerchantAppState>();
    final m = state.merchant;
    if (m == null) return;
    setState(() => _busy = true);
    try {
      final url = await MerchantMediaService.pickUploadAndAttach(
        gateway: state.gateway,
        merchantId: m.merchantId,
        kind: kind,
      );
      if (!mounted) return;
      if (url != null) {
        setState(() {
          if (kind == 'logo') {
            _logoUrl = url;
          } else {
            _bannerUrl = url;
          }
        });
        await state.refreshMerchant();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(kind == 'logo' ? 'Logo updated' : 'Banner updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nxUserFacingMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await context.read<MerchantAppState>().updateProfile(<String, dynamic>{
        'business_name': _business.text.trim(),
        'contact_email': _email.text.trim(),
        'phone': _phone.text.trim(),
        'owner_name': _owner.text.trim(),
        'category': _category.text.trim(),
        'address': _address.text.trim(),
        'business_type': _businessType,
        if (_registration.text.trim().isNotEmpty)
          'business_registration_number': _registration.text.trim(),
        if (_description.text.trim().isNotEmpty) 'store_description': _description.text.trim(),
        if (_openingHours.text.trim().isNotEmpty) 'opening_hours': _openingHours.text.trim(),
        if (_region.text.trim().isNotEmpty) 'region_id': _region.text.trim(),
        if (_city.text.trim().isNotEmpty) 'city_id': _city.text.trim(),
      });
      if (!mounted) return;
      if (res['success'] == true) {
        await context.read<MerchantAppState>().refreshMerchant();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile saved')),
        );
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Profile could not be saved.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Store profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('Branding', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _uploadBrand('logo'),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Store logo'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _uploadBrand('banner'),
                  icon: const Icon(Icons.photo_size_select_large_outlined),
                  label: const Text('Banner'),
                ),
              ),
            ],
          ),
          if (_logoUrl != null && _logoUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Logo: linked', style: Theme.of(context).textTheme.bodySmall),
            ),
          if (_bannerUrl != null && _bannerUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Banner: linked', style: Theme.of(context).textTheme.bodySmall),
            ),
          const Divider(height: 32),
          TextField(controller: _business, decoration: const InputDecoration(labelText: 'Business name')),
          TextField(controller: _email, decoration: const InputDecoration(labelText: 'Contact email')),
          TextField(controller: _phone, decoration: const InputDecoration(labelText: 'Phone')),
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Owner name')),
          TextField(
            controller: _description,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Store description (optional)',
              alignLabelWithHint: true,
            ),
          ),
          TextField(
            controller: _openingHours,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Opening hours (optional)',
              hintText: 'e.g. Mon–Sat 9:00–22:00',
            ),
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
          TextField(
            controller: _registration,
            decoration: const InputDecoration(
              labelText: 'Business registration / CAC (optional)',
            ),
          ),
          TextField(controller: _category, decoration: const InputDecoration(labelText: 'Category')),
          TextField(controller: _address, decoration: const InputDecoration(labelText: 'Address')),
          TextField(controller: _region, decoration: const InputDecoration(labelText: 'Region id (rollout)')),
          TextField(controller: _city, decoration: const InputDecoration(labelText: 'City id (rollout)')),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy ? const CircularProgressIndicator() : const Text('Save'),
          ),
        ],
      ),
    );
  }
}
