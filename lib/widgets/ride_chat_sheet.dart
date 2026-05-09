import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/rider_app_config.dart';
import '../support/friendly_firebase_errors.dart';
import '../support/ride_chat_support.dart';

enum RideChatImageSource { camera, gallery }

class _ChatStatusIndicator extends StatelessWidget {
  const _ChatStatusIndicator({
    required this.status,
    required this.isRead,
    required this.color,
    this.readColor,
    this.failedColor,
  });

  final String status;
  final bool isRead;
  final Color color;
  final Color? readColor;
  final Color? failedColor;

  @override
  Widget build(BuildContext context) {
    if (status == 'sending' || status == 'pending') {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.4,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }
    if (status == 'failed') {
      return Icon(
        Icons.error_outline,
        size: 13,
        color: failedColor ?? color,
      );
    }
    if (isRead) {
      return Icon(
        Icons.done_all,
        size: 14,
        color: readColor ?? color,
      );
    }
    return Icon(Icons.check, size: 14, color: color);
  }
}

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
    this.bankTransferReference = '',
    this.bankTransferAmountLabel = '',
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
  final String bankTransferReference;
  final String bankTransferAmountLabel;

  @override
  State<RideChatSheet> createState() => _RideChatSheetState();
}

class _RideChatSheetState extends State<RideChatSheet> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;

  Future<void> _copyReference(String reference) async {
    await Clipboard.setData(ClipboardData(text: reference));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Payment reference copied')),
    );
  }

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
    if (text.isEmpty) {
      return;
    }

    if (!mounted) {
      return;
    }
    _messageController.clear();
    widget.onDraftChanged?.call('');
    _scrollToBottom(animated: true);

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
      // Optimistic local message is already visible; no additional UI action needed.
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
    } finally {}
  }

  Future<void> _handleRetry(RideChatMessage message) async {
    final error = await widget.onRetryMessage(widget.rideId, message);
    if (!mounted || error == null || error.isEmpty) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(content: Text(coerceUserFacingMessage(error))),
    );
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
    messenger?.showSnackBar(
      SnackBar(content: Text(coerceUserFacingMessage(error))),
    );
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
              if (widget.bankTransferReference.trim().isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF4D6),
                    border: Border.all(color: const Color(0xFFE7C776)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bank Transfer Instructions',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: const Color(0xFF5F4A16),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Please transfer your fare of ${widget.bankTransferAmountLabel.isNotEmpty ? widget.bankTransferAmountLabel : '₦--'} to:\n'
                        'Bank: ${RiderBankTransferConfig.bankName}\n'
                        'Account name: ${RiderBankTransferConfig.accountName}\n'
                        'Account number: ${RiderBankTransferConfig.accountNumber}\n'
                        'Reference: ${widget.bankTransferReference.trim()} (include this exactly in your narration)\n'
                        'Upload your payment proof during or after the trip so your driver can verify.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF6B5A2B),
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFFBEE),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFE2C476),
                                ),
                              ),
                              child: Text(
                                widget.bankTransferReference.trim(),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  color: Color(0xFF4D3E1A),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _copyReference(
                              widget.bankTransferReference.trim(),
                            ),
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('Copy'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF6C551C),
                              side: const BorderSide(color: Color(0xFFD6B563)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
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
                          if (message.senderRole == 'system') {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF8EC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: const Color(0xFFE7C776),
                                  ),
                                ),
                                child: Text(
                                  message.text,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: const Color(0xFF4D3E1A),
                                        height: 1.4,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                            );
                          }
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
                                        _ChatStatusIndicator(
                                          status: message.status,
                                          isRead: message.isRead,
                                          color: Colors.white70,
                                          readColor: const Color(0xFF7CD1FF),
                                          failedColor: const Color(0xFFFFB4A6),
                                        ),
                                        const SizedBox(width: 4),
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
                                            onPressed: () =>
                                                unawaited(_handleRetry(message)),
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
                        prefixIcon: IconButton(
                          tooltip: 'Attach photo',
                          onPressed: () => unawaited(_handleImageSend()),
                          icon: const Icon(Icons.photo_camera_outlined),
                        ),
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
                        backgroundColor: const Color(0xFFB57A2A),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => unawaited(_handleSend()),
                      child: const Icon(Icons.send, color: Colors.white),
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
