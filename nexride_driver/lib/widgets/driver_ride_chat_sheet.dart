import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../support/friendly_firebase_errors.dart';
import '../support/ride_chat_moderation.dart';
import '../support/ride_chat_support.dart';

enum DriverRideChatImageSource { camera, gallery }

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

class DriverRideChatSheet extends StatefulWidget {
  const DriverRideChatSheet({
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
    this.peerName = '',
    this.peerSubtitle = '',
  });

  final String rideId;
  final String currentUserId;
  final ValueListenable<List<RideChatMessage>> messagesListenable;
  final Future<String?> Function(String rideId, String text) onSendMessage;
  final Future<String?> Function(String rideId, RideChatMessage message)
      onRetryMessage;
  final Future<String?> Function(String rideId, DriverRideChatImageSource source)
      onSendImage;
  final VoidCallback? onStartVoiceCall;
  final String initialDraft;
  final ValueChanged<String>? onDraftChanged;
  final bool showCallButton;
  final bool isCallButtonEnabled;
  final bool isCallButtonBusy;
  final String peerName;
  final String peerSubtitle;

  @override
  State<DriverRideChatSheet> createState() => _DriverRideChatSheetState();
}

class _DriverRideChatSheetState extends State<DriverRideChatSheet> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  String _lastMessageListSignature = '';
  bool _isSending = false;
  bool _showHydratingSkeleton = true;
  Timer? _hydrateFallbackTimer;

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
    _messageController.text = widget.initialDraft;
    _lastMessageListSignature =
        _messageListSignature(widget.messagesListenable.value);
    if (widget.messagesListenable.value.isNotEmpty) {
      _showHydratingSkeleton = false;
    }
    widget.messagesListenable.addListener(_onRemoteMessagesChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottom(animated: false));
    _hydrateFallbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) {
        return;
      }
      if (_showHydratingSkeleton) {
        setState(() {
          _showHydratingSkeleton = false;
        });
      }
    });
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
    _hydrateFallbackTimer?.cancel();
    _hydrateFallbackTimer = null;
    widget.messagesListenable.removeListener(_onRemoteMessagesChanged);
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onRemoteMessagesChanged() {
    final messages = widget.messagesListenable.value;
    if (_showHydratingSkeleton) {
      if (mounted) {
        setState(() {
          _showHydratingSkeleton = false;
        });
      } else {
        _showHydratingSkeleton = false;
      }
    }
    final nextSig = _messageListSignature(messages);
    if (nextSig != _lastMessageListSignature) {
      _lastMessageListSignature = nextSig;
      _scrollToBottom(animated: true);
    }
  }

  Widget _buildHydratingSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(14),
      itemCount: 4,
      itemBuilder: (context, index) {
        final alignRight = index.isOdd;
        return Align(
          alignment:
              alignRight ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: MediaQuery.of(context).size.width * (alignRight ? 0.45 : 0.55),
            height: 44,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmModerationWarning(RideChatModerationWarning warning) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Safety check'),
        content: Text(
          '$rideChatModerationDialogBody\n\nDetected: ${warning.reason}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Edit message'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send anyway'),
          ),
        ],
      ),
    );
    return proceed == true;
  }

  Future<void> _handleSend() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) {
      return;
    }

    final moderation = scanRideChatMessage(text);
    if (moderation != null) {
      final proceed = await _confirmModerationWarning(moderation);
      if (!proceed || !mounted) {
        return;
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _isSending = true;
    });
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
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      } else {
        _isSending = false;
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
    messenger?.showSnackBar(
      SnackBar(content: Text(coerceUserFacingMessage(error))),
    );
  }

  Future<void> _handleImageSend() async {
    final source = await showModalBottomSheet<DriverRideChatImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () =>
                  Navigator.of(context).pop(DriverRideChatImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () =>
                  Navigator.of(context).pop(DriverRideChatImageSource.gallery),
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

  String get _headerTitle {
    final name = widget.peerName.trim();
    return name.isEmpty ? 'Ride Chat' : name;
  }

  String _formatMessageTime(int createdAtMs) {
    if (createdAtMs <= 0) {
      return '';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(createdAtMs).toLocal();
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  Widget _buildSafetyBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDCE3EA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, size: 18, color: Color(0xFF4B5563)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              rideChatSafetyBannerText,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: Color(0xFF374151),
              ),
            ),
          ),
        ],
      ),
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
    final sheetHeight = MediaQuery.of(context).size.height * 0.72;
    final subtitle = widget.peerSubtitle.trim();

    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SizedBox(
          height: sheetHeight,
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _headerTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.showCallButton)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: OutlinedButton.icon(
                        onPressed: widget.isCallButtonEnabled &&
                                !widget.isCallButtonBusy
                            ? widget.onStartVoiceCall
                            : null,
                        icon: widget.isCallButtonBusy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.call_outlined, size: 18),
                        label: const Text('Call'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1F2937),
                          side: const BorderSide(color: Color(0xFF1F2937)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                  ),
                ],
              ),
              _buildSafetyBanner(),
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
                            'No messages yet',
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
                                    MediaQuery.of(context).size.width * 0.75,
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
                                    softWrap: true,
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
                                  if (message.createdAt > 0) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      _formatMessageTime(message.createdAt),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF9CA3AF),
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
              Padding(
                padding: EdgeInsets.only(top: 12, bottom: keyboardInset + 12),
                child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      textInputAction: TextInputAction.send,
                      enabled: !_isSending,
                      onChanged: widget.onDraftChanged,
                      onSubmitted: (_) => unawaited(_handleSend()),
                      decoration: InputDecoration(
                        hintText: 'Reply to rider',
                        filled: true,
                        fillColor: const Color(0xFFF4F4F4),
                        prefixIcon: IconButton(
                          tooltip: 'Attach photo',
                          onPressed: _isSending
                              ? null
                              : () => unawaited(_handleImageSend()),
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
                        backgroundColor: const Color(0xFFD4AF37),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _isSending ? null : () => unawaited(_handleSend()),
                      child: _isSending
                          ? const SizedBox(
                              width: 22,
                              height: 22,
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
