import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

class SubscriptionBillingScreen extends StatefulWidget {
  const SubscriptionBillingScreen({super.key});

  @override
  State<SubscriptionBillingScreen> createState() => _SubscriptionBillingScreenState();
}

class _SubscriptionBillingScreenState extends State<SubscriptionBillingScreen> {
  String _targetModel = 'commission';
  final TextEditingController _noteCtl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _noteCtl.dispose();
    super.dispose();
  }

  Future<void> _submit(MerchantAppState state) async {
    setState(() => _busy = true);
    try {
      final res = await state.gateway.merchantRequestPaymentModelChange(<String, dynamic>{
        'payment_model': _targetModel,
        'note': _noteCtl.text.trim(),
      });
      if (!mounted) return;
      if (res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Payment model request could not be sent.',
              ),
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Request submitted. An admin must approve it before your billing model changes.',
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

  @override
  Widget build(BuildContext context) {
    return Consumer<MerchantAppState>(
      builder: (context, state, _) {
        final m = state.merchant;
        final current = (m?.paymentModel ?? 'subscription').toLowerCase();
        return Scaffold(
          appBar: AppBar(title: const Text('Subscription & billing')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text('Payment model', style: Theme.of(context).textTheme.titleMedium),
              Text(m?.paymentModel ?? '—'),
              const SizedBox(height: 12),
              Text('Subscription status', style: Theme.of(context).textTheme.titleMedium),
              Text(m?.subscriptionStatus ?? '—'),
              const SizedBox(height: 12),
              Text('Plan amount', style: Theme.of(context).textTheme.titleMedium),
              Text('₦${m?.subscriptionAmount ?? '—'} ${m?.subscriptionCurrency ?? 'NGN'}'),
              const SizedBox(height: 12),
              Text('Commission rate (commission model)', style: Theme.of(context).textTheme.titleMedium),
              Text('${m?.commissionRate ?? '—'}'),
              const SizedBox(height: 12),
              Text('Withdrawal / payout split', style: Theme.of(context).textTheme.titleMedium),
              Text('${m?.withdrawalPercent ?? '—'}'),
              const Divider(height: 32),
              Text(
                'Request a billing model change',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text('Current model: $current'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey<String>(_targetModel),
                initialValue: _targetModel,
                decoration: const InputDecoration(
                  labelText: 'Requested model',
                  border: OutlineInputBorder(),
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'subscription', child: Text('Subscription')),
                  DropdownMenuItem(value: 'commission', child: Text('Commission')),
                ],
                onChanged: state.isApproved && !_busy
                    ? (v) {
                        if (v != null) setState(() => _targetModel = v);
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Note to admin (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: state.isApproved && !_busy ? () => _submit(state) : null,
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Submit request'),
              ),
              if (!state.isApproved) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  'Approved merchants only can request billing changes.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
