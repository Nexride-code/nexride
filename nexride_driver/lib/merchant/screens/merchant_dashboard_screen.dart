import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';
import '../merchant_portal_functions.dart';
import '../merchant_portal_utils.dart';
import 'merchant_dashboard_status.dart';
import 'merchant_menu_screen.dart';
import 'merchant_orders_screen.dart';
import '../widgets/merchant_va_top_up_sheet.dart';

class MerchantDashboardScreen extends StatefulWidget {
  const MerchantDashboardScreen({super.key, this.initialMerchant});

  final Map<String, dynamic>? initialMerchant;

  @override
  State<MerchantDashboardScreen> createState() =>
      _MerchantDashboardScreenState();
}

class _MerchantDashboardScreenState extends State<MerchantDashboardScreen> {
  Map<String, dynamic>? _m;
  List<Map<String, dynamic>> _documents = const <Map<String, dynamic>>[];
  bool _loading = false;
  bool _docsLoading = false;
  bool _uploadBusy = false;
  String? _err;

  final _resubmitBusiness = TextEditingController();
  final _resubmitOwner = TextEditingController();
  final _resubmitPhone = TextEditingController();
  final _resubmitEmail = TextEditingController();
  final _resubmitAddress = TextEditingController();
  String _resubmitPaymentModel = 'subscription';
  bool _resubmitBusy = false;
  String? _resubmitErr;
  final TextEditingController _walletTopUpAmount = TextEditingController();
  bool _walletTopUpBusy = false;

  @override
  void initState() {
    super.initState();
    _m = widget.initialMerchant;
    _syncResubmitFields();
    if (_m != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDocuments());
    }
  }

  @override
  void dispose() {
    _resubmitBusiness.dispose();
    _resubmitOwner.dispose();
    _resubmitPhone.dispose();
    _resubmitEmail.dispose();
    _resubmitAddress.dispose();
    _walletTopUpAmount.dispose();
    super.dispose();
  }

  void _syncResubmitFields() {
    final m = _m;
    if (m == null) return;
    _resubmitBusiness.text = _str(m['business_name']);
    _resubmitOwner.text = _str(m['owner_name']);
    _resubmitPhone.text = _str(m['phone']);
    _resubmitEmail.text = _str(m['contact_email']);
    _resubmitAddress.text = _str(m['address']);
    _resubmitPaymentModel = _str(m['payment_model']).isEmpty
        ? 'subscription'
        : _str(m['payment_model']);
  }

  String _str(dynamic v) => v?.toString().trim() ?? '';

  Future<void> _loadDocuments() async {
    setState(() => _docsLoading = true);
    try {
      final r =
          await MerchantPortalFunctions().merchantListMyVerificationDocuments();
      if (mpSuccess(r['success']) && r['documents'] is List) {
        final list = <Map<String, dynamic>>[];
        for (final item in r['documents'] as List<dynamic>) {
          if (item is Map) {
            list.add(item.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
        if (mounted) setState(() => _documents = list);
      }
    } finally {
      if (mounted) setState(() => _docsLoading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await MerchantPortalFunctions().merchantGetMyMerchant();
      if (mpSuccess(r['success']) && r['merchant'] is Map) {
        setState(() {
          _m = (r['merchant'] as Map).map(
            (k, v) => MapEntry(k.toString(), v),
          );
          _syncResubmitFields();
        });
        await _loadDocuments();
      } else {
        setState(() => _err = r['reason']?.toString() ?? 'load_failed');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _guessContentType(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<void> _pickAndUpload(String documentType) async {
    final m = _m;
    if (m == null) return;
    final merchantId = _str(m['merchant_id']);
    if (merchantId.isEmpty) return;

    final imageOnly =
        documentType == 'owner_id' || documentType == 'storefront_photo';
    final pick = await FilePicker.platform.pickFiles(
      type: imageOnly ? FileType.image : FileType.custom,
      allowedExtensions: imageOnly
          ? null
          : <String>['jpg', 'jpeg', 'png', 'webp', 'pdf'],
      withData: true,
    );
    if (pick == null || pick.files.isEmpty) return;
    final f = pick.files.first;
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _err = 'Could not read file.');
      return;
    }
    const int maxBytes = 12 * 1024 * 1024;
    if (bytes.length > maxBytes) {
      setState(() => _err = 'File is too large. Maximum size is 12 MB.');
      return;
    }
    final rawName = f.name.trim().isEmpty ? 'upload' : f.name.trim();
    final safe = rawName
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')
        .split('/')
        .last;
    final fname = '${DateTime.now().millisecondsSinceEpoch}_$safe';
    final storagePath =
        'merchant_uploads/$merchantId/verification/$documentType/$fname';
    final ct = _guessContentType(safe);

    setState(() {
      _uploadBusy = true;
      _err = null;
    });
    try {
      final ref = FirebaseStorage.instance.ref(storagePath);
      await ref.putData(
        Uint8List.fromList(bytes),
        SettableMetadata(contentType: ct),
      );
      final res =
          await MerchantPortalFunctions().merchantUploadVerificationDocument(
        <String, dynamic>{
          'document_type': documentType,
          'storage_path': storagePath,
          'file_name': safe,
          'content_type': ct,
        },
      );
      if (!mpSuccess(res['success'])) {
        throw StateError(res['reason']?.toString() ?? 'upload_failed');
      }
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _uploadBusy = false);
    }
  }

  Future<void> _resubmit() async {
    setState(() {
      _resubmitBusy = true;
      _resubmitErr = null;
    });
    try {
      final fn = MerchantPortalFunctions();
      final res = await fn.merchantUpdateMerchantProfile(<String, dynamic>{
        'business_name': _resubmitBusiness.text.trim(),
        'owner_name': _resubmitOwner.text.trim(),
        'phone': _resubmitPhone.text.trim(),
        'contact_email': _resubmitEmail.text.trim().toLowerCase(),
        'address': _resubmitAddress.text.trim(),
        'payment_model': _resubmitPaymentModel,
        'resubmit_application': true,
      });
      if (!mpSuccess(res['success'])) {
        throw StateError(res['reason']?.toString() ?? 'resubmit_failed');
      }
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _resubmitErr = e.toString());
    } finally {
      if (mounted) setState(() => _resubmitBusy = false);
    }
  }

  Future<void> _startVaWalletTopUp() async {
    FocusScope.of(context).unfocus();
    final amt =
        int.tryParse(_walletTopUpAmount.text.replaceAll(',', '').trim()) ?? 0;
    if (amt < 100) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter at least ₦100 to top up.')),
        );
      }
      return;
    }
    setState(() {
      _walletTopUpBusy = true;
      _err = null;
    });
    try {
      final fn = MerchantPortalFunctions();
      final res = await fn.merchantCreateBankTransferTopUp(amountNgn: amt);
      if (!mpSuccess(res['success'])) {
        throw StateError(res['reason']?.toString() ?? 'topup_failed');
      }
      final txRef =
          (res['tx_ref'] ?? res['reference'] ?? '').toString().trim();
      if (txRef.isEmpty) {
        throw StateError('missing_reference');
      }
      if (!mounted) {
        return;
      }
      final refPt =
          FirebaseDatabase.instance.ref('payment_transactions/$txRef');
      final outcome = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => MerchantVaTopUpSheet(
          paymentTransactionsRef: refPt,
          registration: Map<String, dynamic>.from(res),
          onRegenerateWithSameAmount: () =>
              fn.merchantCreateBankTransferTopUp(amountNgn: amt),
        ),
      );
      if (outcome == 'credited' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wallet credit confirmed.')),
        );
        await _refresh();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _err = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _walletTopUpBusy = false);
      }
    }
  }

  List<Map<String, dynamic>> _effectiveDocuments(
    Map<String, dynamic> merchant,
  ) {
    final status =
        _str(merchant['merchant_status'] ?? merchant['status']).toLowerCase();
    if (status != 'pending' || _docsLoading || _documents.isNotEmpty) {
      return _documents;
    }
    return _fallbackVerificationRows(merchant);
  }

  /// When the list callable fails silently or returns empty, still show required uploads.
  List<Map<String, dynamic>> _fallbackVerificationRows(
    Map<String, dynamic> merchant,
  ) {
    final rows = <Map<String, dynamic>>[
      <String, dynamic>{
        'document_type': 'owner_id',
        'status': 'not_submitted',
        'rejection_reason': null,
        'admin_note': null,
      },
      <String, dynamic>{
        'document_type': 'storefront_photo',
        'status': 'not_submitted',
        'rejection_reason': null,
        'admin_note': null,
      },
    ];
    final c = _str(merchant['category']).toLowerCase();
    if (c.contains('restaurant') ||
        c.contains('food') ||
        c.contains('pharmacy')) {
      rows.add(<String, dynamic>{
        'document_type': 'operating_license',
        'status': 'not_submitted',
        'rejection_reason': null,
        'admin_note': null,
      });
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    final effectiveDocs = m == null ? _documents : _effectiveDocuments(m);
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      appBar: AppBar(
        title: const Text('Merchant portal'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _uploadBusy ? null : _refresh,
            icon: _loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          TextButton(
            onPressed: () => FirebaseAuth.instance.signOut(),
            child: const Text('Log out'),
          ),
        ],
      ),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: <Widget>[
                if (_err != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _err!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                MerchantDashboardStatusView(
                  merchant: m,
                  documents: effectiveDocs,
                  docsLoading: _docsLoading,
                  uploadBusy: _uploadBusy,
                  onUploadDocument: _pickAndUpload,
                  resubmitBusiness: _resubmitBusiness,
                  resubmitOwner: _resubmitOwner,
                  resubmitPhone: _resubmitPhone,
                  resubmitEmail: _resubmitEmail,
                  resubmitAddress: _resubmitAddress,
                  resubmitPaymentModel: _resubmitPaymentModel,
                  onPaymentModelChanged: (v) =>
                      setState(() => _resubmitPaymentModel = v),
                  onResubmit: _resubmit,
                  resubmitBusy: _resubmitBusy,
                  resubmitErr: _resubmitErr,
                ),
                if (_str(m['merchant_status'] ?? m['status']).toLowerCase() ==
                    'approved') ...<Widget>[
                  const SizedBox(height: 20),
                  const Text(
                    'Wallet',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          _str(m['wallet_balance_ngn']).isEmpty
                              ? 'Wallet balance unavailable in this view.'
                              : 'Balance (NGN): ${_str(m['wallet_balance_ngn'])}',
                          style: const TextStyle(height: 1.35),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _walletTopUpAmount,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Top-up amount (NGN)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _walletTopUpBusy ? null : _startVaWalletTopUp,
                          child:
                              _walletTopUpBusy
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text(
                                      'Bank transfer via virtual account',
                                    ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'You will receive a unique account number and countdown. Credits apply automatically — no receipt upload.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Commerce',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    tileColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: const Icon(Icons.restaurant_menu),
                    title: const Text('Menu & catalog'),
                    subtitle: const Text('Categories, prices, photos, availability'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MerchantMenuScreen(),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    tileColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: const Icon(Icons.receipt_long),
                    title: const Text('Incoming orders'),
                    subtitle: const Text('Accept, prepare, mark ready, dispatch'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const MerchantOrdersScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
    );
  }
}
