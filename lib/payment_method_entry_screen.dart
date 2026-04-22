import 'package:flutter/material.dart';

import 'config/rider_app_config.dart';
import 'services/payment_methods_service.dart';
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

class _PaymentMethodEntryScreenState extends State<PaymentMethodEntryScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);

  final PaymentMethodsService _service = const PaymentMethodsService();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _detailsController = TextEditingController();
  final TextEditingController _holderController = TextEditingController();
  final TextEditingController _providerRefController = TextEditingController();
  bool _makeDefault = true;
  bool _saving = false;
  late String _provider;

  @override
  void initState() {
    super.initState();
    _provider = widget.type == PaymentMethodType.card
        ? RiderFeatureFlags.paymentProviderCardDefault
        : RiderFeatureFlags.paymentProviderBankDefault;
    if (widget.type == PaymentMethodType.card) {
      _labelController.text = 'Visa';
    } else {
      _labelController.text = 'Bank account';
    }
    _providerRefController.text = 'ref_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  void dispose() {
    _labelController.dispose();
    _detailsController.dispose();
    _holderController.dispose();
    _providerRefController.dispose();
    super.dispose();
  }

  String _maskedDetails() {
    final digits = _detailsController.text.trim();
    if (widget.type == PaymentMethodType.card) {
      return '**** **** **** $digits';
    }

    final bank = _labelController.text.trim().isEmpty
        ? 'Bank account'
        : _labelController.text.trim();
    return '$bank • ****$digits';
  }

  String _displayTitle() {
    final label = _labelController.text.trim();
    final holder = _holderController.text.trim();
    if (widget.type == PaymentMethodType.card) {
      return label.isEmpty ? 'Linked card' : '$label card';
    }
    if (holder.isNotEmpty) {
      return '$label • $holder';
    }
    return label.isEmpty ? 'Linked bank' : label;
  }

  String _detailLabel() {
    final holder = _holderController.text.trim();
    final provider = _provider.replaceAll('_', ' ');
    final pieces = <String>[
      _maskedDetails(),
      if (holder.isNotEmpty) holder,
      provider,
    ];
    return pieces.join(' • ');
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await _service.saveLinkedPaymentMethod(
        PaymentMethodDraft(
          riderId: widget.riderId,
          type: widget.type,
          provider: _provider,
          maskedDetails: _maskedDetails(),
          displayTitle: _displayTitle(),
          detailLabel: _detailLabel(),
          tokenRef: _providerRefController.text.trim(),
          providerReference: _providerRefController.text.trim(),
          country: 'NG',
          last4: _detailsController.text.trim(),
          makeDefault: _makeDefault,
        ),
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.type == PaymentMethodType.card ? 'Card' : 'Bank account'} record saved. Live payment processing is still disabled.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save payment method: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCard = widget.type == PaymentMethodType.card;

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
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 20,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Integration-ready setup',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This saves a backend payment-method record that is ready for a future PSP connection. No live payment is processed yet.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Form(
                    key: _formKey,
                    child: Column(
                      children: <Widget>[
                        TextFormField(
                          controller: _labelController,
                          decoration: InputDecoration(
                            labelText: isCard ? 'Card brand' : 'Bank name',
                            filled: true,
                            fillColor: _cream,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          validator: (value) {
                            if ((value ?? '').trim().isEmpty) {
                              return isCard
                                  ? 'Enter a card brand'
                                  : 'Enter a bank name';
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
                            labelText: isCard
                                ? 'Last 4 card digits'
                                : 'Last 4 account digits',
                            filled: true,
                            fillColor: _cream,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          validator: (value) {
                            final normalized = (value ?? '').trim();
                            if (normalized.length != 4 ||
                                int.tryParse(normalized) == null) {
                              return 'Enter exactly 4 digits';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 4),
                        TextFormField(
                          controller: _holderController,
                          decoration: InputDecoration(
                            labelText: isCard
                                ? 'Cardholder name'
                                : 'Account holder name',
                            filled: true,
                            fillColor: _cream,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: _cream,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.online_prediction_outlined),
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _provider,
                                  decoration: const InputDecoration(
                                    labelText: 'Provider',
                                    border: InputBorder.none,
                                  ),
                                  items: const <DropdownMenuItem<String>>[
                                    DropdownMenuItem<String>(
                                      value: 'paystack_ready',
                                      child: Text('Paystack (integration-ready)'),
                                    ),
                                    DropdownMenuItem<String>(
                                      value: 'flutterwave_ready',
                                      child: Text('Flutterwave (integration-ready)'),
                                    ),
                                  ],
                                  onChanged: _saving
                                      ? null
                                      : (value) {
                                          if (value == null) {
                                            return;
                                          }
                                          setState(() {
                                            _provider = value;
                                          });
                                        },
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _providerRefController,
                          decoration: InputDecoration(
                            labelText: 'Provider token/reference',
                            helperText:
                                'Store PSP token/reference only. Never store PAN/CVV.',
                            filled: true,
                            fillColor: _cream,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          validator: (value) {
                            if ((value ?? '').trim().length < 6) {
                              return 'Enter a valid token/reference';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        SwitchListTile.adaptive(
                          value: _makeDefault,
                          activeThumbColor: _gold,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Set as default payment method'),
                          subtitle: const Text(
                            'Online payments will use the default method once PSP processing is connected.',
                          ),
                          onChanged: (value) {
                            setState(() {
                              _makeDefault = value;
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
                            onPressed: _saving ? null : _save,
                            child: Text(
                              _saving ? 'Saving...' : 'Save payment method',
                            ),
                          ),
                        ),
                      ],
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
}
