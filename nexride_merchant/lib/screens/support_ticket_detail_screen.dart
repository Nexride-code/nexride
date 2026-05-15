import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';

class SupportTicketDetailScreen extends StatefulWidget {
  const SupportTicketDetailScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  State<SupportTicketDetailScreen> createState() => _SupportTicketDetailScreenState();
}

class _SupportTicketDetailScreenState extends State<SupportTicketDetailScreen> {
  bool _loading = true;
  bool _replyBusy = false;
  String? _error;
  Map<String, dynamic>? _ticket;
  List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];
  final _reply = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<MerchantAppState>().gateway.supportGetTicket(widget.ticketId);
      if (res['success'] != true) {
        _error = nxMapFailureMessage(
          Map<String, dynamic>.from(res),
          nxSupportUnavailableMessage(),
        );
      } else {
        final t = res['ticket'];
        _ticket = t is Map ? Map<String, dynamic>.from(t) : null;
        final m = res['messages'];
        if (m is List) {
          _messages = m.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false);
        } else {
          _messages = const <Map<String, dynamic>>[];
        }
      }
    } catch (e) {
      _error = nxUserFacingMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    setState(() => _replyBusy = true);
    try {
      final res =
          await context.read<MerchantAppState>().gateway.merchantAppendSupportTicketMessage(<String, dynamic>{
        'ticketId': widget.ticketId,
        'body': text,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        _reply.clear();
        await _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                nxSupportUnavailableMessage(),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nxUserFacingMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _replyBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Ticket ${widget.ticketId}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? NxInlineError(message: _error!)
              : Column(
                  children: <Widget>[
                    if (_ticket != null)
                      ListTile(
                        title: Text(_ticket!['subject']?.toString() ?? ''),
                        subtitle: Text('Status: ${_ticket!['status']}'),
                      ),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _messages.length,
                        itemBuilder: (context, i) {
                          final m = _messages[i];
                          return ListTile(
                            title: Text(m['body']?.toString() ?? ''),
                            subtitle: Text('${m['role'] ?? 'user'} • ${m['authorUid']}'),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _reply,
                              decoration: const InputDecoration(hintText: 'Reply…'),
                            ),
                          ),
                          IconButton(
                            onPressed: _replyBusy || _loading ? null : _send,
                            icon: _replyBusy
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.send),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
