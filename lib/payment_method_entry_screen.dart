import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services/payment_methods_service.dart';
import 'services/rider_ride_cloud_functions_service.dart';
import 'support/friendly_firebase_errors.dart';
import 'support/payment_method_support.dart';

class PaymentMethodEntryScreen extends StatefulWidget {
  const PaymentMethodEntryScreen({
    super.key,
    required this.riderId,
    required this.type,
  });

  final String riderId;
  final PaymentMethodType type;

  @override
  State<PaymentMethodEntryScreen> createState() =>
      _PaymentMethodEntryScreenState();
}

class _PaymentMethodEntryScreenState extends State<PaymentMethodEntryScreen>
    with WidgetsBindingObserver {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);

  final PaymentMethodsService _service = const PaymentMethodsService();
  final RiderRideCloudFunctionsService _rideCloud =
      RiderRideCloudFunctionsService.instance;

  final GlobalKey<FormState> _bankFormKey = GlobalKey<FormState>();
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _detailsController = TextEditingController();
  final TextEditingController _holderController = TextEditingController();
  bool _bankMakeDefault = true;
  bool _busy = false;
  bool _checkoutAbandon = false;
  String _pendingCardLinkReference = '';
  bool _cardLinkVerificationInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.type == PaymentMethodType.bank) {
      _labelController.text = 'Bank account';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkoutAbandon = true;
    _labelController.dispose();
    _detailsController.dispose();
    _holderController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _pendingCardLinkReference.isNotEmpty &&
        !_cardLinkVerificationInFlight &&
        !_checkoutAbandon) {
      unawaited(_verifyCardLinkReference(_pendingCardLinkReference));
    }
  }

  String _maskedBankDetails() {
    final digits = _detailsController.text.trim();
    final bank = _labelController.text.trim().isEmpty
        ? 'Bank account'
        : _labelController.text.trim();
    return '$bank • ****$digits';
  }

  String _displayBankTitle() {
    final label = _labelController.text.trim();
    final holder = _holderController.text.trim();
    if (holder.isNotEmpty) {
      return '$label • $holder';
    }
    return label.isEmpty ? 'Linked bank' : label;
  }

  Future<void> _saveBankDraft() async {
    if (!_bankFormKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      final refPlaceholder =
          'bank_manual_${DateTime.now().millisecondsSinceEpoch}';
      await _service.saveLinkedPaymentMethod(
        PaymentMethodDraft(
          riderId: widget.riderId,
          type: PaymentMethodType.bank,
          brand: _labelController.text.trim(),
          provider: 'flutterwave',
          maskedDetails: _maskedBankDetails(),
          displayTitle: _displayBankTitle(),
          detailLabel: _maskedBankDetails(),
          tokenRef: refPlaceholder,
          providerReference: refPlaceholder,
          country: 'NG',
          last4: _detailsController.text.trim(),
          makeDefault: _bankMakeDefault,
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bank account saved.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyFirebaseError(error, debugLabel: 'paymentMethod.save'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _startFlutterwaveCardLink() async {
    setState(() {
      _busy = true;
      _checkoutAbandon = false;
    });
    Map<String, dynamic> init = const <String, dynamic>{};
    try {
      final user = FirebaseAuth.instance.currentUser;
      init = await _rideCloud.initiateFlutterwaveCardLinkIntent(
        <String, dynamic>{
          if (user?.displayName != null &&
              user!.displayName!.trim().isNotEmpty)
            'customer_name': user.displayName!.trim(),
          if (user?.email != null && user!.email!.trim().isNotEmpty)
            'email': user.email!.trim(),
        },
      );
      if (!mounted) return;
      if (init['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_cardLinkInitMessage(init)),
          ),
        );
        return;
      }
      final amount = init['amount'] ?? 100;
      final cur = '${init['currency'] ?? 'NGN'}'.toUpperCase();
      final urlRaw = '${init['authorization_url'] ?? init['authorizationUrl'] ?? ''}';
      final txRef = '${init['tx_ref'] ?? init['txRef'] ?? ''}'.trim();
      final pk = '${init['public_key'] ?? ''}'.trim();

      final uri = Uri.tryParse(urlRaw.trim());
      if (uri == null || !uri.hasScheme || pk.isEmpty || txRef.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'We could not start card setup. Please try again in a moment.',
            ),
          ),
        );
        return;
      }

      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (!launched) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open the payment page on this device.'),
          ),
        );
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Complete the ₦$amount $cur authorization in your browser, then return here. NexRide verifies on our servers.',
          ),
        ),
      );
      _pendingCardLinkReference = txRef;

      Map<String, dynamic>? finalizeRes;
      for (var i = 0; i < 90; i++) {
        if (!mounted || _checkoutAbandon) break;
        await Future<void>.delayed(const Duration(seconds: 2));
        if (i % 3 != 2 && i != 0) continue;
        try {
          finalizeRes = await _verifyCardLinkReference(txRef);
          if (finalizeRes['success'] == true) {
            break;
          }
          if (kDebugMode) {
            debugPrint(
              '[CARD_LINK_VERIFY_PENDING] tx=$txRef res=$finalizeRes',
            );
          }
        } catch (error, stackTrace) {
          debugPrint('[CARD_LINK_VERIFY_ERR] tx=$txRef err=$error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }

      if (!mounted) return;
      if (finalizeRes?['success'] == true) {
        _pendingCardLinkReference = '';
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Card linked successfully!')),
        );
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'We could not confirm your card yet. If payment succeeded, return to the app and we will retry automatically.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyFirebaseError(error, debugLabel: 'paymentMethod.cardLink'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<Map<String, dynamic>> _verifyCardLinkReference(String reference) async {
    _cardLinkVerificationInFlight = true;
    try {
      return await _rideCloud.verifyFlutterwavePayment(
        reference: reference,
        verifyCardLinkOnly: true,
      );
    } finally {
      _cardLinkVerificationInFlight = false;
    }
  }

  String _cardLinkInitMessage(Map<String, dynamic> init) {
    final reason = '${init['reason'] ?? ''}'.trim();
    final msg = '${init['message'] ?? init['note'] ?? ''}'.trim();
    if (kDebugMode && msg.isNotEmpty) {
      return 'Could not start card setup ($reason): $msg';
    }
    if (kDebugMode && reason.isNotEmpty) {
      return 'Could not start card setup: $reason';
    }
    return 'Could not start card setup right now. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.type == PaymentMethodType.card) {
      return Scaffold(
        backgroundColor: _cream,
        appBar: AppBar(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          title: Text(widget.type.label),
          centerTitle: true,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 20,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Link your card',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'We use Flutterwave’s secure checkout in your browser. A small '
                      'one-time ₦100-style authorization (Flutterwave shows the exact '
                      'amount) saves your card safely for trips — you never type card '
                      'details inside this app.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.66),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _busy ? null : _startFlutterwaveCardLink,
                        child: Text(_busy ? 'Opening checkout…' : 'Continue'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        title: Text(widget.type.label),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 20,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Form(
                key: _bankFormKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Bank account',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Add your bank payout details.',
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.66),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _labelController,
                      decoration: InputDecoration(
                        labelText: 'Bank name',
                        filled: true,
                        fillColor: _cream,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      validator: (value) {
                        if ((value ?? '').trim().isEmpty) {
                          return 'Enter a bank name';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _detailsController,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: InputDecoration(
                        labelText: 'Last 3–4 account digits',
                        filled: true,
                        fillColor: _cream,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      validator: (value) {
                        final normalized = (value ?? '').trim();
                        if (normalized.length < 3 ||
                            normalized.length > 4 ||
                            int.tryParse(normalized) == null) {
                          return 'Enter 3–4 digits from your account';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 4),
                    TextFormField(
                      controller: _holderController,
                      decoration: InputDecoration(
                        labelText: 'Account holder name',
                        filled: true,
                        fillColor: _cream,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      value: _bankMakeDefault,
                      activeThumbColor: _gold,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Set as default payment method'),
                      onChanged: (value) {
                        setState(() {
                          _bankMakeDefault = value;
                        });
                      },
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _busy ? null : _saveBankDraft,
                        child: Text(_busy ? 'Saving…' : 'Save payment method'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
