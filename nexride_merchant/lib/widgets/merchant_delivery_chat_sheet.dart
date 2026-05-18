import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

const String _kSafetyNotice =
    'Keep communication respectful. Do not share private contact or payment '
    'details. Harassment, threats, sexual content, or abuse are prohibited.';

class MerchantDeliveryChatSheet extends StatefulWidget {
  const MerchantDeliveryChatSheet({super.key, required this.deliveryId});

  final String deliveryId;

  @override
  State<MerchantDeliveryChatSheet> createState() =>
      _MerchantDeliveryChatSheetState();
}

class _MerchantDeliveryChatSheetState extends State<MerchantDeliveryChatSheet> {
  final TextEditingController _controller = TextEditingController();
  StreamSubscription<rtdb.DatabaseEvent>? _sub;
  final List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _sub = rtdb.FirebaseDatabase.instance
        .ref('delivery_chats/${widget.deliveryId}/messages')
        .onValue
        .listen((event) {
      final raw = event.snapshot.value;
      if (raw is! Map || !mounted) {
        return;
      }
      final list = <Map<String, dynamic>>[];
      raw.forEach((key, value) {
        if (value is Map) {
          list.add(<String, dynamic>{
            'id': '$key',
            ...Map<String, dynamic>.from(value),
          });
        }
      });
      list.sort((a, b) {
        final ta = (a['created_at_ms'] as num?)?.toInt() ?? 0;
        final tb = (b['created_at_ms'] as num?)?.toInt() ?? 0;
        return ta.compareTo(tb);
      });
      setState(() => _messages..clear()..addAll(list));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final user = FirebaseAuth.instance.currentUser;
    final text = _controller.text.trim();
    if (user == null || text.isEmpty) {
      return;
    }
    final messageNode = rtdb.FirebaseDatabase.instance
        .ref('delivery_chats/${widget.deliveryId}/messages')
        .push();
    final messageId = messageNode.key ?? '';
    final now = DateTime.now().millisecondsSinceEpoch;
    await messageNode.set(<String, dynamic>{
      'sender_id': user.uid,
      'sender_role': 'merchant',
      'text': text,
      'created_at_ms': now,
      'status': 'sent',
    });
    if (messageId.isNotEmpty) {
      try {
        await FirebaseFunctions.instanceFor(region: 'us-central1')
            .httpsCallable('notifyDeliveryChatMessage')
            .call(<String, dynamic>{
          'deliveryId': widget.deliveryId,
          'messageId': messageId,
        });
      } catch (_) {}
    }
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: const Color(0xFFFFF3E0),
            padding: const EdgeInsets.all(12),
            child: Text(_kSafetyNotice, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final m = _messages[index];
                final mine = m['sender_id'] == uid;
                return Align(
                  alignment:
                      mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: mine
                          ? const Color(0xFFE8F5E9)
                          : const Color(0xFFF5F5F5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(m['text']?.toString() ?? ''),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Message driver…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(onPressed: _send, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
