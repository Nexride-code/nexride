import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

/// Read-only delivery chat transcript for admin/support.
class AdminDeliveryChatTranscriptSheet extends StatefulWidget {
  const AdminDeliveryChatTranscriptSheet({super.key, required this.deliveryId});

  final String deliveryId;

  @override
  State<AdminDeliveryChatTranscriptSheet> createState() =>
      _AdminDeliveryChatTranscriptSheetState();
}

class _AdminDeliveryChatTranscriptSheetState
    extends State<AdminDeliveryChatTranscriptSheet> {
  StreamSubscription<DatabaseEvent>? _sub;
  final List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  Future<void> _attach() async {
    await _sub?.cancel();
    try {
      _sub = FirebaseDatabase.instance
          .ref('delivery_chats/${widget.deliveryId}/messages')
          .onValue
          .listen(
        (event) {
          if (!mounted) {
            return;
          }
          final raw = event.snapshot.value;
          final list = <Map<String, dynamic>>[];
          if (raw is Map) {
            raw.forEach((key, value) {
              if (value is Map) {
                list.add(<String, dynamic>{'id': '$key', ...Map<String, dynamic>.from(value)});
              }
            });
          }
          list.sort((a, b) {
            final ta = (a['created_at_ms'] as num?)?.toInt() ?? 0;
            final tb = (b['created_at_ms'] as num?)?.toInt() ?? 0;
            return ta.compareTo(tb);
          });
          setState(() {
            _error = null;
            _messages
              ..clear()
              ..addAll(list);
          });
        },
        onError: (Object e) {
          if (mounted) {
            setState(() => _error = e.toString());
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Delivery chat · ${widget.deliveryId}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Read-only transcript. Do not share private contact details with parties.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Sync error: $_error'),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              final m = _messages[index];
              final role = m['sender_role']?.toString() ?? 'unknown';
              return ListTile(
                dense: true,
                title: Text(m['text']?.toString() ?? ''),
                subtitle: Text('$role · ${m['sender_id'] ?? ''}'),
              );
            },
          ),
        ),
      ],
    );
  }
}
