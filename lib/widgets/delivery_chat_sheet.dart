import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../support/delivery_chat_support.dart';
import '../support/ride_chat_support.dart';
import 'ride_chat_sheet.dart';

/// Delivery chat UI — reuses [RideChatSheet] with delivery message mapping.
class DeliveryChatSheet extends StatelessWidget {
  const DeliveryChatSheet({
    super.key,
    required this.deliveryId,
    required this.currentUserId,
    required this.messagesListenable,
    required this.onSendMessage,
    required this.onRetryMessage,
    this.onStartVoiceCall,
    this.showCallButton = false,
    this.isCallButtonEnabled = true,
    this.isCallButtonBusy = false,
  });

  final String deliveryId;
  final String currentUserId;
  final ValueListenable<List<DeliveryChatMessage>> messagesListenable;
  final Future<String?> Function(String deliveryId, String text) onSendMessage;
  final Future<String?> Function(String deliveryId, DeliveryChatMessage message)
      onRetryMessage;
  final VoidCallback? onStartVoiceCall;
  final bool showCallButton;
  final bool isCallButtonEnabled;
  final bool isCallButtonBusy;

  static RideChatMessage _toRide(DeliveryChatMessage m) {
    return RideChatMessage(
      id: m.id,
      rideId: m.deliveryId,
      messageId: m.messageId,
      senderId: m.senderId,
      senderRole: m.senderRole == 'customer' ? 'rider' : m.senderRole,
      type: m.type,
      text: m.text,
      imageUrl: m.imageUrl,
      createdAt: m.createdAt,
      status: m.status,
      isRead: m.isRead,
      localTempId: m.localTempId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<DeliveryChatMessage>>(
      valueListenable: messagesListenable,
      builder: (context, deliveryMessages, _) {
        final rideMessages =
            deliveryMessages.map(_toRide).toList(growable: false);
        return Column(
          children: <Widget>[
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF3E0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                kDeliveryChatSafetyNotice,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: Colors.brown.shade800,
                ),
              ),
            ),
            Expanded(
              child: RideChatSheet(
                rideId: deliveryId,
                currentUserId: currentUserId,
                messagesListenable: _RideMessageListenable(rideMessages),
                onSendMessage: onSendMessage,
                onRetryMessage: (rideId, msg) {
                  final original = deliveryMessages.firstWhere(
                    (m) => m.id == msg.id,
                    orElse: () => DeliveryChatMessage(
                      id: msg.id,
                      deliveryId: deliveryId,
                      messageId: msg.messageId,
                      senderId: msg.senderId,
                      senderRole: msg.senderRole,
                      type: msg.type,
                      text: msg.text,
                      imageUrl: msg.imageUrl,
                      createdAt: msg.createdAt,
                      status: msg.status,
                      isRead: msg.isRead,
                      localTempId: msg.localTempId,
                    ),
                  );
                  return onRetryMessage(deliveryId, original);
                },
                onSendImage: (_, __) async => 'Image upload not enabled yet.',
                onStartVoiceCall: onStartVoiceCall,
                showCallButton: showCallButton,
                isCallButtonEnabled: isCallButtonEnabled,
                isCallButtonBusy: isCallButtonBusy,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RideMessageListenable extends ValueListenable<List<RideChatMessage>> {
  _RideMessageListenable(this.value);

  @override
  final List<RideChatMessage> value;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
