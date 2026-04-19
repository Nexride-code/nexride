import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../support/ride_chat_support.dart';

class DriverRideChatSheet extends StatefulWidget {
  const DriverRideChatSheet({
    super.key,
    required this.rideId,
    required this.currentUserId,
    required this.messagesListenable,
    required this.onSendMessage,
    this.onStartVoiceCall,
    this.showCallButton = false,
    this.isCallButtonEnabled = true,
    this.isCallButtonBusy = false,
  });

  final String rideId;
  final String currentUserId;
  final ValueListenable<List<RideChatMessage>> messagesListenable;
  final Future<String?> Function(String rideId, String text) onSendMessage;
  final VoidCallback? onStartVoiceCall;
  final bool showCallButton;
  final bool isCallButtonEnabled;
  final bool isCallButtonBusy;

  @override
  State<DriverRideChatSheet> createState() => _DriverRideChatSheetState();
}

class _DriverRideChatSheetState extends State<DriverRideChatSheet> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  String _lastMessageListSignature = '';

  String _messageListSignature(List<RideChatMessage> messages) {
    if (messages.isEmpty) {
      return '0';
    }
    final buf = StringBuffer();
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (i > 0) {
        buf.write('|');
      }
      buf.write('${m.id}:${m.status}');
    }
    return buf.toString();
  }

  @override
  void initState() {
    super.initState();
    _lastMessageListSignature =
        _messageListSignature(widget.messagesListenable.value);
    widget.messagesListenable.addListener(_onRemoteMessagesChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottom(animated: false));
  }

  @override
  void didUpdateWidget(DriverRideChatSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messagesListenable != widget.messagesListenable) {
      oldWidget.messagesListenable.removeListener(_onRemoteMessagesChanged);
      _lastMessageListSignature =
          _messageListSignature(widget.messagesListenable.value);
      widget.messagesListenable.addListener(_onRemoteMessagesChanged);
    }
  }

  @override
  void dispose() {
    widget.messagesListenable.removeListener(_onRemoteMessagesChanged);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onRemoteMessagesChanged() {
    final messages = widget.messagesListenable.value;
    final nextSig = _messageListSignature(messages);
    if (nextSig != _lastMessageListSignature) {
      _lastMessageListSignature = nextSig;
      _scrollToBottom(animated: true);
    }
  }

  Future<void> _handleSend() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _sending = true;
    });

    try {
      final errorMessage = await widget.onSendMessage(widget.rideId, text);
      if (!mounted) {
        return;
      }
      if (errorMessage != null && errorMessage.isNotEmpty) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () {
                unawaited(_handleSend());
              },
            ),
          ),
        );
        return;
      }
      _messageController.clear();
      _scrollToBottom(animated: true);
    } catch (_) {
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text('Unable to send message right now.'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              unawaited(_handleSend());
            },
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  void _scrollToBottom({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }

      final target = _scrollController.position.maxScrollExtent;
      if (animated) {
        unawaited(
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          ),
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.58,
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Ride Chat',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.showCallButton)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7E7AE),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: IconButton(
                        onPressed: widget.isCallButtonEnabled &&
                                !widget.isCallButtonBusy
                            ? widget.onStartVoiceCall
                            : null,
                        tooltip: 'Call rider',
                        icon: widget.isCallButtonBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF1F2937),
                                ),
                              )
                            : const Icon(
                                Icons.call_outlined,
                                color: Color(0xFF1F2937),
                              ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7F7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: ValueListenableBuilder<List<RideChatMessage>>(
                    valueListenable: widget.messagesListenable,
                    builder: (context, messages, _) {
                      if (messages.isEmpty) {
                        return const Center(
                          child: Text(
                            'Reply to your rider here.',
                            style: TextStyle(color: Colors.black54),
                          ),
                        );
                      }

                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(14),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final message = messages[index];
                          final isMine = message.isSentBy(widget.currentUserId);

                          return Align(
                            alignment: isMine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.72,
                              ),
                              decoration: BoxDecoration(
                                color: isMine
                                    ? const Color(0xFF1F2937)
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: isMine
                                    ? CrossAxisAlignment.end
                                    : CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    message.text,
                                    style: TextStyle(
                                      color: isMine
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                  if (isMine) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            message.deliveryLabel,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),
                                        if (message.status == 'failed') ...[
                                          const SizedBox(width: 8),
                                          TextButton(
                                            style: TextButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.zero,
                                              minimumSize: Size.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              visualDensity:
                                                  VisualDensity.compact,
                                            ),
                                            onPressed: _sending
                                                ? null
                                                : () {
                                                    _messageController.text =
                                                        message.text;
                                                    unawaited(_handleSend());
                                                  },
                                            child: const Text(
                                              'Retry',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                decoration:
                                                    TextDecoration.underline,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_handleSend()),
                      decoration: InputDecoration(
                        hintText: 'Reply to rider',
                        filled: true,
                        fillColor: const Color(0xFFF4F4F4),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 52,
                    width: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color(0xFFD4AF37),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _sending ? null : () => unawaited(_handleSend()),
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.send, color: Colors.black),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
