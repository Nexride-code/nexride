import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/merchant_app_state.dart';
import '../services/merchant_payment_return_bus.dart';
import '../utils/nx_callable_messages.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  final TextEditingController _amountCtl = TextEditingController();
  final TextEditingController _verifyTxRefCtl = TextEditingController();
  bool _busy = false;
  String? _lastFlutterwaveTxRef;
  bool _balancesLoaded = false;
  bool _syncingBalances = false;
  List<Map<String, dynamic>> _ledger = <Map<String, dynamic>>[];
  StreamSubscription<MerchantPaymentReturnEvent>? _paymentReturnSub;
  String? _paymentReturnBanner;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshBalances());
    _paymentReturnSub = MerchantPaymentReturnBus.instance.stream.listen(_onPaymentReturn);
  }

  Future<void> _onPaymentReturn(MerchantPaymentReturnEvent event) async {
    if (!mounted) {
      return;
    }
    if (event.isCancelled) {
      setState(() {
        _paymentReturnBanner =
            'Payment cancelled. You can try again when ready — your wallet was not charged.';
        _verifyTxRefCtl.text = event.txRef;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment cancelled')),
      );
      return;
    }
    setState(() {
      _paymentReturnBanner = 'Complete verification below if you finished checkout.';
      _verifyTxRefCtl.text = event.txRef;
      _lastFlutterwaveTxRef = event.txRef;
    });
  }

  String _fmtNgn(num? v, {required bool loaded}) {
    if (!loaded) return '…';
    if (v == null) return '₦0';
    final n = v is int ? v : v.round();
    return '₦$n';
  }

  Future<void> _refreshBalances() async {
    final state = context.read<MerchantAppState>();
    setState(() => _syncingBalances = true);
    try {
      await state.refreshMerchant();
      final led = await state.gateway.merchantListWalletLedger();
      if (!mounted) return;
      if (led['success'] == true) {
        final raw = led['entries'] ?? led['ledger'] ?? led['items'] ?? led['transactions'];
        if (raw is List) {
          _ledger = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false);
        } else {
          _ledger = const <Map<String, dynamic>>[];
        }
      } else {
        _ledger = const <Map<String, dynamic>>[];
      }
      setState(() => _balancesLoaded = true);
    } catch (_) {
      if (mounted) setState(() => _balancesLoaded = true);
    } finally {
      if (mounted) setState(() => _syncingBalances = false);
    }
  }

  @override
  void dispose() {
    unawaited(_paymentReturnSub?.cancel());
    _amountCtl.dispose();
    _verifyTxRefCtl.dispose();
    super.dispose();
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open checkout URL')),
      );
    }
  }

  Future<void> _startFlutterwaveTopUp(MerchantAppState state) async {
    final raw = _amountCtl.text.trim().replaceAll(',', '');
    final amount = int.tryParse(raw);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount in NGN')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      final res = await state.gateway.merchantStartWalletTopUpFlutterwave(<String, dynamic>{
        'amount_ngn': amount,
        'email': user?.email,
      });
      if (!mounted) return;
      if (res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Top-up could not be started.',
              ),
            ),
          ),
        );
        return;
      }
      final txRef = '${res['tx_ref'] ?? ''}'.trim();
      final link = '${res['authorization_url'] ?? ''}'.trim();
      setState(() {
        _lastFlutterwaveTxRef = txRef.isEmpty ? null : txRef;
        _verifyTxRefCtl.text = txRef;
      });
      if (link.isNotEmpty) {
        await _launchUrl(link);
      }
      if (!mounted) return;
      await state.refreshMerchant();
      if (!mounted) return;
      await _refreshBalances();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'After paying in the browser, tap “Verify Flutterwave payment” using your tx reference.',
          ),
        ),
      );
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

  Future<void> _verifyFlutterwave(MerchantAppState state) async {
    final ref = _verifyTxRefCtl.text.trim();
    if (ref.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the transaction reference (tx_ref)')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await state.gateway.verifyPayment(ref);
      if (!mounted) return;
      if (res['success'] != true) {
        final reason = '${res['reason'] ?? res['reason_code'] ?? ''}'.trim();
        if (reason == 'payment_cancelled') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Payment was cancelled — you can try again.')),
          );
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Payment could not be verified.',
              ),
            ),
          ),
        );
        return;
      }
      await state.refreshMerchant();
      if (!mounted) return;
      await _refreshBalances();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment verified — wallet updated when successful.')),
      );
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

  Future<void> _createBankTopUp(MerchantAppState state) async {
    final raw = _amountCtl.text.trim().replaceAll(',', '');
    final amount = int.tryParse(raw);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount in NGN')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await state.gateway.merchantCreateBankTransferTopUp(<String, dynamic>{
        'amount_ngn': amount,
      });
      if (!mounted) return;
      if (res['success'] != true) {
        final reason = '${res['reason'] ?? ''}'.trim();
        final friendly = reason == 'official_bank_not_configured'
            ? 'Bank transfer details are not configured yet. Please contact NexRide support.'
            : nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Could not create bank top-up.',
              );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendly)),
        );
        return;
      }
      await _showBankTopUpSheet(context, state, res);
      await state.refreshMerchant();
      await _refreshBalances();
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

  Future<void> _showBankTopUpSheet(
    BuildContext context,
    MerchantAppState state,
    Map<String, dynamic> res,
  ) async {
    final requestId = '${res['request_id'] ?? ''}'.trim();
    final narration = '${res['narration_reference'] ?? ''}'.trim();
    final expiresMs = res['expires_at_ms'] is num ? (res['expires_at_ms'] as num).toInt() : 0;
    final bank = res['bank'] is Map ? Map<String, dynamic>.from(res['bank'] as Map) : <String, dynamic>{};
    final prefix = '${res['proof_upload_prefix'] ?? ''}'.trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Bank transfer top-up', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('Request ID: $requestId'),
                if (expiresMs > 0)
                  Text(
                    'Expires: ${DateTime.fromMillisecondsSinceEpoch(expiresMs).toLocal()}',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                const Divider(height: 24),
                Text('Bank: ${bank['bank_name'] ?? '—'}'),
                Text('Account name: ${bank['account_name'] ?? '—'}'),
                Text('Account number: ${bank['account_number'] ?? '—'}'),
                const SizedBox(height: 8),
                SelectableText('Narration / reference: $narration'),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: narration.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: narration));
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(content: Text('Copied narration')),
                              );
                            }
                          },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy narration'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Transfer exactly ₦${res['amount_ngn'] ?? ''} and include the narration above. '
                  'Then upload a screenshot or PDF of the transfer.',
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: prefix.isEmpty || requestId.isEmpty
                      ? null
                      : () => _pickAndUploadProof(ctx, state, requestId, prefix),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload payment proof'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickAndUploadProof(
    BuildContext sheetContext,
    MerchantAppState state,
    String requestId,
    String prefix,
  ) async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 88);
    if (x == null) return;
    final file = File(x.path);
    final ext = x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
    final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    final objectPath = '${prefix}proof_${DateTime.now().millisecondsSinceEpoch}.$ext';
    setState(() => _busy = true);
    try {
      await FirebaseStorage.instance.ref(objectPath).putFile(
            file,
            SettableMetadata(contentType: contentType),
          );
      final attach = await state.gateway.merchantAttachBankTransferTopUpProof(<String, dynamic>{
        'request_id': requestId,
        'storage_path': objectPath,
        'content_type': contentType,
      });
      if (!mounted) return;
      if (attach['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(attach),
                'Proof could not be attached.',
              ),
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Proof uploaded — NexRide admin will review.')),
      );
      if (sheetContext.mounted) Navigator.of(sheetContext).pop();
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

  @override
  Widget build(BuildContext context) {
    return Consumer<MerchantAppState>(
      builder: (context, state, _) {
        final m = state.merchant;
        return Scaffold(
          appBar: AppBar(title: const Text('Wallet & payments')),
          body: Stack(
            children: <Widget>[
              ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Balances',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      if (_syncingBalances)
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        IconButton(
                          tooltip: 'Refresh balances',
                          onPressed: _busy ? null : _refreshBalances,
                          icon: const Icon(Icons.refresh),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('Wallet: ${_fmtNgn(m?.walletBalanceNgn, loaded: _balancesLoaded)}'),
                  Text('Withdrawable: ${_fmtNgn(m?.withdrawableEarningsNgn, loaded: _balancesLoaded)}'),
                  if (_paymentReturnBanner != null) ...<Widget>[
                    const SizedBox(height: 12),
                    Material(
                      color: const Color(0xFFE8F4FD),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _paymentReturnBanner!,
                          style: const TextStyle(fontSize: 13, height: 1.35),
                        ),
                      ),
                    ),
                  ],
                  if (_ledger.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text('Recent ledger (${_ledger.length})', style: Theme.of(context).textTheme.titleSmall),
                    ..._ledger.take(8).map(
                          (e) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${e['type'] ?? e['kind'] ?? e['description'] ?? 'Entry'}'),
                            subtitle: Text('${e['created_at'] ?? e['at'] ?? ''}'),
                            trailing: Text('${e['amount_ngn'] ?? e['delta_ngn'] ?? e['amount'] ?? ''}'),
                          ),
                        ),
                  ],
                  Text(
                    'Amount (NGN)',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  TextField(
                    controller: _amountCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      hintText: 'e.g. 5000',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Flutterwave card top-up',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: state.isApproved && !_busy ? () => _startFlutterwaveTopUp(state) : null,
                    child: const Text('Pay with Flutterwave'),
                  ),
                  if (_lastFlutterwaveTxRef != null) ...<Widget>[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _verifyTxRefCtl,
                      decoration: const InputDecoration(
                        labelText: 'Tx reference to verify',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: state.isApproved && !_busy ? () => _verifyFlutterwave(state) : null,
                      child: const Text('Verify Flutterwave payment'),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Manual bank transfer',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Creates a pending request (30 minutes). Official NexRide account details are returned from the server. '
                    'Wallet is credited only after admin approval.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: state.isApproved && !_busy ? () => _createBankTopUp(state) : null,
                    child: const Text('Start manual bank transfer'),
                  ),
                  if (!state.isApproved) ...<Widget>[
                    const SizedBox(height: 24),
                    Text(
                      'Your merchant profile must be approved before wallet actions.',
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ],
              ),
              if (_busy)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
