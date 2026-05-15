import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';
import 'support_ticket_detail_screen.dart';

class SupportTicketsScreen extends StatefulWidget {
  const SupportTicketsScreen({super.key});

  @override
  State<SupportTicketsScreen> createState() => _SupportTicketsScreenState();
}

class _SupportTicketsScreenState extends State<SupportTicketsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<MerchantAppState>().gateway.merchantListMySupportTickets();
      if (res['success'] != true) {
        _error = nxMapFailureMessage(
          Map<String, dynamic>.from(res),
          nxSupportUnavailableMessage(),
        );
        _rows = const <Map<String, dynamic>>[];
      } else {
        final raw = res['tickets'];
        if (raw is List) {
          _rows = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false);
        } else {
          _rows = const <Map<String, dynamic>>[];
        }
      }
    } catch (e) {
      _error = nxUserFacingMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final subject = TextEditingController();
    final body = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New ticket'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(controller: subject, decoration: const InputDecoration(labelText: 'Subject')),
            TextField(
              controller: body,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Message'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final m = context.read<MerchantAppState>().merchant;
    final res = await context.read<MerchantAppState>().gateway.supportCreateTicket(<String, dynamic>{
      'subject': subject.text.trim(),
      'body': body.text.trim(),
      'merchantId': m?.merchantId,
      'userType': 'merchant',
    });
    if (!mounted) return;
    if (res['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ticket ${res['ticketId']}')),
      );
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nxMapFailureMessage(
              Map<String, dynamic>.from(res),
              'Ticket could not be created.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Column(
        children: <Widget>[
          NxInlineError(message: _error!),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _create,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('Ticket'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _rows.isEmpty
            ? ListView(
                children: const <Widget>[
                  SizedBox(height: 120),
                  NxEmptyState(
                    title: 'No support tickets',
                    subtitle: 'Create a ticket for payouts, menu, or technical issues.',
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _rows.length,
                itemBuilder: (context, i) {
                  final t = _rows[i];
                  final id = '${t['id']}';
                  return Card(
                    child: ListTile(
                      title: Text(t['subject']?.toString() ?? 'Ticket'),
                      subtitle: Text('Status: ${t['status']}'),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SupportTicketDetailScreen(ticketId: id),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }
}
