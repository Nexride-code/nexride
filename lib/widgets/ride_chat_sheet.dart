import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../support/ride_chat_support.dart';

enum RideChatImageSource { camera, gallery }

class RideChatSheet extends StatefulWidget {
  const RideChatSheet({
    super.key,
    required this.rideId,
    required this.currentUserId,
    required this.messagesListenable,
    required this.onSendMessage,
    required this.onRetryMessage,
    required this.onSendImage,
    this.onStartVoiceCall,
    this.initialDraft = '',
    this.onDraftChanged,
    this.showCallButton = false,
    this.isCallButtonEnabled = true,
    this.isCallButtonBusy = false,
  });

  final String rideId;
  final String currentUserId;
  final ValueListenable<List<RideChatMessage>> messagesListenable;
  final Future<String?> Function(String rideId, String text) onSendMessage;
  final Future<String?> Function(String rideId, RideChatMessage message)
      onRetryMessage;
  final Future<String?> Function(String rideId, RideChatImageSource source)
      onSendImage;
  final VoidCallback? onStartVoiceCall;
  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;
  final bool showCallButton;
  final bool isCallButtonEnabled;
  final bool isCallButtonBusy;

  @override
  State<RideChatSheet> createState() => _RideChatSheetState();
}

class _RideChatSheetState extends State<RideChatSheet> {
  static const Duration _sendTimeout = Duration(seconds: 10);
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _sending = false;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    _messageController.text = widget.initialDraft;
    _lastMessageCount = widget.messagesListenable.value.length;
    widget.messagesListenable.addListener(_onRemoteMessagesChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottom(animated: false));
  }

  @override
  void didUpdateWidget(RideChatSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messagesListenable != widget.messagesListenable) {
      oldWidget.messagesListenable.removeListener(_onRemoteMessagesChanged);
      _lastMessageCount = widget.messagesListenable.value.length;
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
    final nextCount = widget.messagesListenable.value.length;
    if (nextCount != _lastMessageCount) {
      _lastMessageCount = nextCount;
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
      final errorMessage = await widget
          .onSendMessage(widget.rideId, text)
          .timeout(
            _sendTimeout,
            onTimeout: () =>
                'Sending this message took too long. Please try again.',
          );
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
      widget.onDraftChanged?.call('');
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

  Future<void> _handleRetry(RideChatMessage message) async {
    final error = await widget.onRetryMessage(widget.rideId, message);
    if (!mounted || error == null || error.isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _handleImageSend() async {
    final source = await showModalBottomSheet<RideChatImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.of(context).pop(RideChatImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(context).pop(RideChatImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) {
      return;
    }
    final error = await widget.onSendImage(widget.rideId, source);
    if (!mounted || error == null || error.isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(error)));
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
                        color: const Color(0xFFF6E7CF),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: IconButton(
                        onPressed:
                            widget.isCallButtonEnabled &&
                                !widget.isCallButtonBusy
                            ? widget.onStartVoiceCall
                            : null,
                        tooltip: 'Call driver',
                        icon: widget.isCallButtonBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFFB57A2A),
                                ),
                              )
                            : const Icon(
                                Icons.call_outlined,
                                color: Color(0xFFB57A2A),
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
                            'Send a message to your driver.',
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
                                    ? const Color(0xFFB57A2A)
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
                                  if (message.hasImage) ...[
                                    const SizedBox(height: 8),
                                    GestureDetector(
                                      onTap: () {
                                        showDialog<void>(
                                          context: context,
                                          builder: (_) => Dialog(
                                            insetPadding: const EdgeInsets.all(16),
                                            child: InteractiveViewer(
                                              child: Image.network(
                                                message.imageUrl,
                                                fit: BoxFit.contain,
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image.network(
                                          message.imageUrl,
                                          height: 130,
                                          width: 130,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ],
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
                                                : () => unawaited(
                                                      _handleRetry(message),
                                                    ),
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
                      onChanged: widget.onDraftChanged,
                      onSubmitted: (_) => unawaited(_handleSend()),
                      decoration: InputDecoration(
                        hintText: 'Message your driver',
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
                        backgroundColor: const Color(0xFFEEE6DB),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _sending ? null : () => unawaited(_handleImageSend()),
                      child: const Icon(Icons.photo_camera_outlined, color: Colors.black87),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 52,
                    width: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color(0xFFB57A2A),
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
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, color: Colors.white),
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
