import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/nexride_official_bank_account_service.dart';
import '../support/friendly_firebase_errors.dart';
import '../support/ride_chat_moderation.dart';
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
    this.bankTransferUsesFlutterwaveVa = false,
    this.bankTransferPaymentTxRef = '',
    this.peerName = '',
    this.peerSubtitle = '',
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
  /// When true, bank instructions load from [payment_transactions/{tx_ref}] (Flutterwave VA).
  final bool bankTransferUsesFlutterwaveVa;
  final String bankTransferPaymentTxRef;
  final String peerName;
  final String peerSubtitle;

  @override
  State<RideChatSheet> createState() => _RideChatSheetState();
}

class _RideChatSheetState extends State<RideChatSheet> {
  static final Map<String, bool> _paymentExpandedByRide = <String, bool>{};

  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  int _lastMessageCount = 0;
  NexrideOfficialBankAccount? _officialBank;
  bool _officialBankLoaded = false;
  Map<String, dynamic>? _vaPaymentRow;
  bool _vaPaymentLoaded = false;
  bool _paymentDetailsExpanded = false;
  bool _isSending = false;
  bool _showHydratingSkeleton = true;
  Timer? _hydrateFallbackTimer;

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
    _paymentDetailsExpanded =
        _paymentExpandedByRide[widget.rideId.trim()] ?? false;
    _messageController.text = widget.initialDraft;
    _lastMessageCount = widget.messagesListenable.value.length;
    if (_lastMessageCount > 0) {
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
    if (widget.bankTransferUsesFlutterwaveVa &&
        widget.bankTransferPaymentTxRef.trim().isNotEmpty) {
      unawaited(_loadVaPaymentInstructions());
    } else {
      unawaited(_loadOfficialBank());
    }
  }

  Future<void> _loadVaPaymentInstructions() async {
    final txRef = widget.bankTransferPaymentTxRef.trim();
    try {
      final snap = await FirebaseDatabase.instance
          .ref('payment_transactions/$txRef')
          .get()
          .timeout(const Duration(seconds: 12));
      final raw = snap.value;
      if (raw is Map) {
        final row = raw.map((k, v) => MapEntry(k.toString(), v));
        final provider =
            (row['provider']?.toString() ?? '').trim().toLowerCase();
        if (provider == 'flutterwave_va') {
          if (!mounted) return;
          setState(() {
            _vaPaymentRow = row;
            _vaPaymentLoaded = true;
            _officialBankLoaded = true;
          });
          return;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _vaPaymentLoaded = true;
      _officialBankLoaded = true;
    });
  }

  Future<void> _loadOfficialBank() async {
    try {
      final b = await NexrideOfficialBankAccountService.instance.fetch();
      if (!mounted) return;
      setState(() {
        _officialBank = b;
        _officialBankLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _officialBankLoaded = true;
      });
    }
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
    _hydrateFallbackTimer?.cancel();
    _hydrateFallbackTimer = null;
    widget.messagesListenable.removeListener(_onRemoteMessagesChanged);
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onRemoteMessagesChanged() {
    final nextCount = widget.messagesListenable.value.length;
    if (_showHydratingSkeleton && nextCount >= 0) {
      if (mounted) {
        setState(() {
          _showHydratingSkeleton = false;
        });
      } else {
        _showHydratingSkeleton = false;
      }
    }
    if (nextCount != _lastMessageCount) {
      _lastMessageCount = nextCount;
      _scrollToBottom(animated: true);
    }
  }

  void _togglePaymentExpanded() {
    setState(() {
      _paymentDetailsExpanded = !_paymentDetailsExpanded;
      _paymentExpandedByRide[widget.rideId.trim()] = _paymentDetailsExpanded;
    });
  }

  String _bankTransferCompactSummary() {
    final amt = widget.bankTransferAmountLabel.isNotEmpty
        ? widget.bankTransferAmountLabel
        : '₦--';
    if (widget.bankTransferUsesFlutterwaveVa && _vaPaymentRow != null) {
      final row = _vaPaymentRow!;
      final bank = (row['bank_name'] ?? '').toString().trim();
      final acct = (row['account_number'] ?? '').toString().trim();
      final expMs = row['expires_at_ms'] ?? row['va_expires_at_ms'];
      var expiry = '';
      final exp = expMs is num
          ? expMs.toInt()
          : int.tryParse(expMs?.toString() ?? '') ?? 0;
      if (exp > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(exp).toLocal();
        expiry =
            ' · Exp ${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '$amt · ${bank.isEmpty ? 'Bank' : bank} · ${acct.isEmpty ? '—' : acct}$expiry';
    }
    final ob = _officialBank;
    if (ob != null) {
      return '$amt · ${ob.bankName} · ${ob.accountNumber}';
    }
    return '$amt · Tap to view payment details';
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

  String _bankTransferInstructionsBody() {
    final ref = widget.bankTransferReference.trim();
    final amt = widget.bankTransferAmountLabel.isNotEmpty
        ? widget.bankTransferAmountLabel
        : '₦--';
    if (widget.bankTransferUsesFlutterwaveVa) {
      if (!_vaPaymentLoaded) {
        return 'Please transfer your fare of $amt to the virtual account below.\n'
            'Loading payment account details…\n'
            'Reference: $ref';
      }
      final row = _vaPaymentRow;
      if (row == null || row.isEmpty) {
        return 'Please transfer your fare of $amt using your payment reference.\n'
            'Virtual account details could not be loaded. Open the payment sheet from the map or try again.\n'
            'Reference: $ref';
      }
      final bankName = (row['bank_name'] ?? '').toString().trim();
      final acctNum = (row['account_number'] ?? '').toString().trim();
      final acctName = (row['account_name'] ?? '').toString().trim();
      final txRef = (row['tx_ref'] ?? ref).toString().trim();
      final amountNgn = row['total_ngn'] ?? row['amount'] ?? row['amount_ngn'];
      final amountLabel = amountNgn is num
          ? '₦${amountNgn.round()}'
          : amt;
      final expMs = row['expires_at_ms'] ?? row['va_expires_at_ms'];
      var expiryLine = '';
      final exp = expMs is num
          ? expMs.toInt()
          : int.tryParse(expMs?.toString() ?? '') ?? 0;
      if (exp > 0) {
        final dt = DateTime.fromMillisecondsSinceEpoch(exp).toLocal();
        expiryLine =
            'Expires: ${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} '
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}\n';
      }
      return 'Transfer exactly $amountLabel to this virtual account:\n'
          'Bank: ${bankName.isEmpty ? '—' : bankName}\n'
          'Account name: ${acctName.isEmpty ? '—' : acctName}\n'
          'Account number: ${acctNum.isEmpty ? '—' : acctNum}\n'
          'Reference / tx_ref: $txRef\n'
          '$expiryLine'
          'Payment confirms automatically when Flutterwave receives your transfer. '
          'No receipt upload required.';
    }
    if (!_officialBankLoaded) {
      return 'Please transfer your fare of $amt to NexRide.\n'
          'Loading official bank details…\n'
          'Reference: $ref (include this exactly in your narration)\n'
          'Upload your payment proof during or after the trip so your driver can verify.';
    }
    final ob = _officialBank;
    if (ob == null) {
      return 'Please transfer your fare of $amt to the official NexRide account.\n'
          'Bank details could not be loaded. Contact support@nexride.africa for instructions.\n'
          'Reference: $ref (include this exactly in your narration)\n'
          'Upload your payment proof during or after the trip so your driver can verify.';
    }
    return 'Please transfer your fare of $amt to:\n'
        'Bank: ${ob.bankName}\n'
        'Account name: ${ob.accountName}\n'
        'Account number: ${ob.accountNumber}\n'
        'Reference: $ref (include this exactly in your narration)\n'
        'Upload your payment proof during or after the trip so your driver can verify.';
  }

  String get _bankTransferBannerTitle => 'Bank transfer payment';

  bool get _hasBankTransfer =>
      widget.bankTransferReference.trim().isNotEmpty;

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

  Widget _buildPaymentCollapsible(double maxHeight) {
    return Material(
      color: const Color(0xFFFFF8EC),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _togglePaymentExpanded,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE7C776)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _bankTransferBannerTitle,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF5F4A16),
                        ),
                      ),
                    ),
                    Text(
                      _paymentDetailsExpanded
                          ? 'Hide details'
                          : 'View payment details',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFB57A2A),
                      ),
                    ),
                    Icon(
                      _paymentDetailsExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: const Color(0xFFB57A2A),
                    ),
                  ],
                ),
              ),
              if (!_paymentDetailsExpanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: Text(
                    _bankTransferCompactSummary(),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B5A2B),
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (_paymentDetailsExpanded)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _bankTransferInstructionsBody(),
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
                                side: const BorderSide(
                                  color: Color(0xFFD6B563),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
    final sheetHeight = MediaQuery.of(context).size.height * 0.72;
    final paymentMaxHeight = sheetHeight * 0.25;
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
                          foregroundColor: const Color(0xFFB57A2A),
                          side: const BorderSide(color: Color(0xFFB57A2A)),
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
              if (_hasBankTransfer)
                _buildPaymentCollapsible(paymentMaxHeight),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F7F7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: ValueListenableBuilder<List<RideChatMessage>>(
                    valueListenable: widget.messagesListenable,
                    builder: (context, messages, _) {
                      if (_showHydratingSkeleton && messages.isEmpty) {
                        return _buildHydratingSkeleton();
                      }
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
                        hintText: 'Message your driver',
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
                        backgroundColor: const Color(0xFFB57A2A),
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
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, color: Colors.white),
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
