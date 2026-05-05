import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'map_screen.dart';
import 'services/rider_active_trip_session_service.dart';
import 'services/user_support_ticket_service.dart';

const List<String> _kSupportCategories = <String>[
  'account',
  'trip_issue',
  'payment',
  'safety',
  'driver_behavior',
  'app_issue',
  'other',
];

const List<String> _kSupportPriorities = <String>[
  'low',
  'normal',
  'high',
  'urgent',
];

class SupportCenterScreen extends StatefulWidget {
  const SupportCenterScreen({
    super.key,
    required this.userId,
    this.createdByType = 'rider',
  });

  final String userId;
  final String createdByType;

  @override
  State<SupportCenterScreen> createState() => _SupportCenterScreenState();
}

class _SupportCenterScreenState extends State<SupportCenterScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);
  static const Color _ink = Color(0xFF111111);

  final UserSupportTicketService _ticketService =
      const UserSupportTicketService();
  final RiderActiveTripSessionService _activeTripSessionService =
      RiderActiveTripSessionService.instance;
  int _reloadSeed = 0;

  Stream<List<UserSupportTicketSummary>> get _ticketsStream =>
      _ticketService.watchOwnTickets(
        userId: widget.userId,
        createdByType: widget.createdByType,
      );

  @override
  void initState() {
    super.initState();
    unawaited(
      _activeTripSessionService.restoreActiveTripForCurrentUser(
        source: 'support_center.init',
      ),
    );
  }

  Future<void> _openCreateTicket() async {
    final ticketDocumentId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _CreateSupportTicketScreen(
          userId: widget.userId,
          createdByType: widget.createdByType,
          ticketService: _ticketService,
        ),
      ),
    );

    if (!mounted || ticketDocumentId == null || ticketDocumentId.isEmpty) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Support ticket created.')));

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SupportTicketDetailScreen(
          userId: widget.userId,
          createdByType: widget.createdByType,
          ticketDocumentId: ticketDocumentId,
          ticketService: _ticketService,
        ),
      ),
    );
  }

  Future<void> _openTicket(UserSupportTicketSummary ticket) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SupportTicketDetailScreen(
          userId: widget.userId,
          createdByType: widget.createdByType,
          ticketDocumentId: ticket.documentId,
          ticketService: _ticketService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: _ink,
        title: const Text('Support Center'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _openCreateTicket,
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('New ticket'),
          ),
        ],
      ),
      body: StreamBuilder<List<UserSupportTicketSummary>>(
        key: ValueKey<int>(_reloadSeed),
        stream: _ticketsStream,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<UserSupportTicketSummary>> snapshot,
            ) {
              if (snapshot.hasError) {
                return _SupportStateCard(
                  icon: Icons.error_outline_rounded,
                  title: 'Support inbox unavailable',
                  message:
                      'We could not load your support tickets right now. Retry in a moment and your existing conversations will appear here.',
                  actionLabel: 'Retry',
                  onAction: () {
                    setState(() {
                      _reloadSeed += 1;
                    });
                  },
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _SupportStateCard(
                  icon: Icons.support_agent_outlined,
                  title: 'Loading support inbox',
                  message:
                      'Fetching your ticket history, reply status, and linked trip context.',
                  isLoading: true,
                );
              }

              final tickets =
                  snapshot.data ?? const <UserSupportTicketSummary>[];
              final unreadCount = tickets
                  .where(
                    (UserSupportTicketSummary ticket) =>
                        ticket.hasUnreadSupportReply,
                  )
                  .length;
              final openCount = tickets
                  .where(
                    (UserSupportTicketSummary ticket) => !ticket.isResolved,
                  )
                  .length;

              return Column(
                children: <Widget>[
                  ValueListenableBuilder<RiderActiveTripSession?>(
                    valueListenable: _activeTripSessionService.sessionNotifier,
                    builder: (
                      BuildContext context,
                      RiderActiveTripSession? session,
                      Widget? _,
                    ) {
                      if (session == null ||
                          !_activeTripSessionService.hasActiveTrip) {
                        return const SizedBox.shrink();
                      }
                      debugPrint(
                        '[RIDER_ACTIVE_TRIP_BANNER] source=support_center status=${session.status} rideId=${session.rideId}',
                      );
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: _SupportTripBanner(
                          status: session.status,
                          onTap: () {
                            debugPrint(
                              '[RIDER_NAV_RETURN_TO_TRIP] source=support_center rideId=${session.rideId}',
                            );
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const MapScreen(),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: <Color>[Color(0xFF111111), Color(0xFF3A2B14)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x26000000),
                            blurRadius: 22,
                            offset: Offset(0, 14),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(
                                  Icons.support_agent_rounded,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      'NexRide Support',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Create a ticket, follow the conversation, and reply when support asks for more details.',
                                      style: TextStyle(
                                        color: Color(0xFFE8DDD1),
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: <Widget>[
                              _SupportMetricChip(
                                label: 'Total',
                                value: tickets.length.toString(),
                              ),
                              _SupportMetricChip(
                                label: 'Open',
                                value: openCount.toString(),
                              ),
                              _SupportMetricChip(
                                label: 'Unread replies',
                                value: unreadCount.toString(),
                                highlight: unreadCount > 0,
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: _openCreateTicket,
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: _ink,
                            ),
                            icon: const Icon(Icons.add_circle_outline_rounded),
                            label: const Text('Report issue / support'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: tickets.isEmpty
                        ? _SupportStateCard(
                            icon: Icons.mark_email_read_outlined,
                            title: 'No support tickets yet',
                            message:
                                'If you have a trip problem, payment issue, dispute, or account question, open a ticket here and the NexRide support team will pick it up.',
                            actionLabel: 'Create ticket',
                            onAction: _openCreateTicket,
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                            itemCount: tickets.length,
                            separatorBuilder: (_, int separatorIndex) =>
                                const SizedBox(height: 12),
                            itemBuilder: (BuildContext context, int index) {
                              final ticket = tickets[index];
                              return _SupportTicketListTile(
                                ticket: ticket,
                                onTap: () => _openTicket(ticket),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
      ),
    );
  }
}

class _SupportTripBanner extends StatelessWidget {
  const _SupportTripBanner({required this.status, required this.onTap});

  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF111111),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFB57A2A)),
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.alt_route_rounded, color: Color(0xFFB57A2A)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Trip active • ${status.replaceAll('_', ' ')}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateSupportTicketScreen extends StatefulWidget {
  const _CreateSupportTicketScreen({
    required this.userId,
    required this.createdByType,
    required this.ticketService,
  });

  final String userId;
  final String createdByType;
  final UserSupportTicketService ticketService;

  @override
  State<_CreateSupportTicketScreen> createState() =>
      _CreateSupportTicketScreenState();
}

class _CreateSupportTicketScreenState
    extends State<_CreateSupportTicketScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _cream = Color(0xFFF7F2EA);

  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _tripIdController = TextEditingController();

  late Future<List<UserSupportTripOption>> _tripOptionsFuture;
  String _category = _kSupportCategories.first;
  String _priority = 'normal';
  bool _isSubmitting = false;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _tripOptionsFuture = _loadTripOptions();
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _messageController.dispose();
    _tripIdController.dispose();
    super.dispose();
  }

  Future<List<UserSupportTripOption>> _loadTripOptions() {
    return widget.ticketService.fetchRecentTrips(
      userId: widget.userId,
      createdByType: widget.createdByType,
    );
  }

  Future<void> _submit() async {
    final subject = _subjectController.text.trim();
    final message = _messageController.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      setState(() {
        _inlineError = 'Subject and message are required before sending.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _inlineError = null;
    });

    try {
      final ticketDocumentId = await widget.ticketService.createTicket(
        createdByUserId: widget.userId,
        createdByType: widget.createdByType,
        subject: subject,
        message: message,
        category: _category,
        priority: _priority,
        tripId: _tripIdController.text,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(ticketDocumentId);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSubmitting = false;
        _inlineError =
            'We could not submit that ticket right now. Please retry in a moment.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        title: const Text('Create Support Ticket'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(26),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 16,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Tell the support team what happened',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use this form for complaints, disputes, missing payments, trip issues, or account help. Link a trip if it is relevant so the support team can open it faster.',
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.66),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _subjectController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Subject',
                      hintText: 'Example: Fare mismatch after Flutterwave payment',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _category,
                          decoration: const InputDecoration(
                            labelText: 'Category',
                          ),
                          items: _kSupportCategories
                              .map(
                                (String value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(_labelize(value)),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (String? value) {
                            setState(() {
                              _category = value ?? _category;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _priority,
                          decoration: const InputDecoration(
                            labelText: 'Priority',
                          ),
                          items: _kSupportPriorities
                              .map(
                                (String value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(_labelize(value)),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (String? value) {
                            setState(() {
                              _priority = value ?? _priority;
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _tripIdController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Trip ID (optional)',
                      hintText:
                          'Paste or type a trip ID if this is trip-related',
                    ),
                  ),
                  const SizedBox(height: 14),
                  FutureBuilder<List<UserSupportTripOption>>(
                    future: _tripOptionsFuture,
                    builder:
                        (
                          BuildContext context,
                          AsyncSnapshot<List<UserSupportTripOption>> snapshot,
                        ) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: LinearProgressIndicator(minHeight: 3),
                            );
                          }

                          final trips =
                              snapshot.data ?? const <UserSupportTripOption>[];
                          if (trips.isEmpty) {
                            return Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF7F2EA),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Icon(
                                    Icons.info_outline_rounded,
                                    color: Colors.black.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Recent trip suggestions are not available right now. You can still submit the ticket and optionally type the trip ID manually.',
                                      style: TextStyle(
                                        color: Colors.black.withValues(
                                          alpha: 0.66,
                                        ),
                                        height: 1.45,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _tripOptionsFuture = _loadTripOptions();
                                      });
                                    },
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Recent trips',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: trips
                                    .map(
                                      (UserSupportTripOption trip) =>
                                          ActionChip(
                                            label: Text(
                                              trip.tripId,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            avatar: const Icon(
                                              Icons.route_outlined,
                                              size: 18,
                                            ),
                                            onPressed: () {
                                              _tripIdController.text =
                                                  trip.tripId;
                                            },
                                          ),
                                    )
                                    .toList(growable: false),
                              ),
                            ],
                          );
                        },
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _messageController,
                    minLines: 6,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      hintText:
                          'Describe what happened, when it happened, and what outcome you need from support.',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (_inlineError != null) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      _inlineError!,
                      style: const TextStyle(
                        color: Color(0xFFB42318),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isSubmitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.send_outlined),
                      label: Text(
                        _isSubmitting ? 'Submitting...' : 'Submit ticket',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupportTicketDetailScreen extends StatefulWidget {
  const _SupportTicketDetailScreen({
    required this.userId,
    required this.createdByType,
    required this.ticketDocumentId,
    required this.ticketService,
  });

  final String userId;
  final String createdByType;
  final String ticketDocumentId;
  final UserSupportTicketService ticketService;

  @override
  State<_SupportTicketDetailScreen> createState() =>
      _SupportTicketDetailScreenState();
}

class _SupportTicketDetailScreenState
    extends State<_SupportTicketDetailScreen> {
  static const Color _gold = Color(0xFFB57A2A);

  final TextEditingController _replyController = TextEditingController();
  bool _isSendingReply = false;
  int? _lastMarkedReplyMillis;

  @override
  void initState() {
    super.initState();
    unawaited(
      widget.ticketService.markTicketViewed(
        ticketDocumentId: widget.ticketDocumentId,
      ),
    );
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  void _markViewedIfNeeded(UserSupportTicketSummary ticket) {
    if (!ticket.hasUnreadSupportReply) {
      return;
    }
    final millis =
        ticket.lastSupportReplyAt?.millisecondsSinceEpoch ??
        ticket.lastReplyAt?.millisecondsSinceEpoch;
    if (millis == null || _lastMarkedReplyMillis == millis) {
      return;
    }
    _lastMarkedReplyMillis = millis;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        widget.ticketService.markTicketViewed(
          ticketDocumentId: widget.ticketDocumentId,
        ),
      );
    });
  }

  Future<void> _sendReply(UserSupportTicketSummary ticket) async {
    final message = _replyController.text.trim();
    if (message.isEmpty || _isSendingReply) {
      return;
    }
    setState(() {
      _isSendingReply = true;
    });

    try {
      final authUser = FirebaseAuth.instance.currentUser;
      final senderName = authUser?.displayName?.trim().isNotEmpty ?? false
          ? authUser!.displayName!.trim()
          : ticket.requesterName;

      await widget.ticketService.addReply(
        ticketDocumentId: widget.ticketDocumentId,
        senderId: widget.userId,
        senderRole: widget.createdByType,
        senderName: senderName,
        message: message,
      );

      if (!mounted) {
        return;
      }
      _replyController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Reply sent to support.')));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('We could not send that reply right now.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSendingReply = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserSupportTicketSummary?>(
      stream: widget.ticketService.watchTicket(
        ticketDocumentId: widget.ticketDocumentId,
      ),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<UserSupportTicketSummary?> ticketSnapshot,
          ) {
            final ticket = ticketSnapshot.data;
            if (ticketSnapshot.hasError) {
              return Scaffold(
                backgroundColor: const Color(0xFFF7F2EA),
                appBar: AppBar(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  title: const Text('Ticket detail'),
                ),
                body: const _SupportStateCard(
                  icon: Icons.error_outline_rounded,
                  title: 'Ticket unavailable',
                  message:
                      'This support conversation could not be loaded right now. Please go back and retry from your support inbox.',
                ),
              );
            }

            if (ticket == null) {
              return Scaffold(
                backgroundColor: const Color(0xFFF7F2EA),
                appBar: AppBar(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  title: const Text('Ticket detail'),
                ),
                body: const _SupportStateCard(
                  icon: Icons.description_outlined,
                  title: 'Ticket not found',
                  message:
                      'This support ticket is no longer available in your inbox.',
                ),
              );
            }

            if (ticket.createdByUserId != widget.userId ||
                ticket.createdByType != widget.createdByType) {
              return Scaffold(
                backgroundColor: const Color(0xFFF7F2EA),
                appBar: AppBar(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  title: const Text('Ticket detail'),
                ),
                body: const _SupportStateCard(
                  icon: Icons.lock_outline_rounded,
                  title: 'Ticket access blocked',
                  message:
                      'This ticket does not belong to the signed-in account.',
                ),
              );
            }

            _markViewedIfNeeded(ticket);

            return Scaffold(
              backgroundColor: const Color(0xFFF7F2EA),
              appBar: AppBar(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                title: Text(ticket.ticketId),
              ),
              body: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x12000000),
                            blurRadius: 14,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            ticket.subject,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _DetailChip(label: _labelize(ticket.status)),
                              _DetailChip(label: _labelize(ticket.priority)),
                              _DetailChip(label: _labelize(ticket.category)),
                              if (ticket.tripId.isNotEmpty)
                                _DetailChip(label: 'Trip ${ticket.tripId}'),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Created ${_formatDate(ticket.createdAt)} • Last update ${_formatDate(ticket.updatedAt)}',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.62),
                            ),
                          ),
                          if (ticket.resolution.trim().isNotEmpty) ...<Widget>[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF4F1EA),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                'Resolution: ${ticket.resolution}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                          if (ticket.tripId.isNotEmpty ||
                              ticket.tripSnapshot.pickupAddress.isNotEmpty ||
                              ticket
                                  .tripSnapshot
                                  .destinationAddress
                                  .isNotEmpty) ...<Widget>[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF7F2EA),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  const Text(
                                    'Linked trip',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    ticket.tripSnapshot.pickupAddress.isEmpty
                                        ? 'Trip ID: ${ticket.tripId}'
                                        : '${ticket.tripSnapshot.pickupAddress} -> ${ticket.tripSnapshot.destinationAddress}',
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.74,
                                      ),
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: StreamBuilder<List<UserSupportTicketMessage>>(
                      stream: widget.ticketService.watchPublicMessages(
                        ticketDocumentId: widget.ticketDocumentId,
                      ),
                      builder:
                          (
                            BuildContext context,
                            AsyncSnapshot<List<UserSupportTicketMessage>>
                            messageSnapshot,
                          ) {
                            if (messageSnapshot.hasError) {
                              return const _SupportStateCard(
                                icon: Icons.chat_bubble_outline_rounded,
                                title: 'Conversation unavailable',
                                message:
                                    'The ticket exists, but the message thread could not be loaded right now.',
                              );
                            }

                            if (messageSnapshot.connectionState ==
                                    ConnectionState.waiting &&
                                !messageSnapshot.hasData) {
                              return const _SupportStateCard(
                                icon: Icons.forum_outlined,
                                title: 'Loading conversation',
                                message:
                                    'Fetching the public message thread for this ticket.',
                                isLoading: true,
                              );
                            }

                            final messages =
                                messageSnapshot.data ??
                                const <UserSupportTicketMessage>[];

                            if (messages.isEmpty) {
                              return const _SupportStateCard(
                                icon: Icons.forum_outlined,
                                title: 'No messages yet',
                                message:
                                    'The original ticket is saved, but no support reply or follow-up message has been added yet.',
                              );
                            }

                            return ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                              itemCount: messages.length,
                              itemBuilder: (BuildContext context, int index) {
                                final message = messages[index];
                                final fromUser = !message.isFromSupport;
                                return Align(
                                  alignment: fromUser
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      maxWidth: 540,
                                    ),
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: fromUser
                                          ? const Color(0xFFF5E8D3)
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: const <BoxShadow>[
                                        BoxShadow(
                                          color: Color(0x0F000000),
                                          blurRadius: 10,
                                          offset: Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Text(
                                              message.senderName,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              _formatDate(message.createdAt),
                                              style: TextStyle(
                                                color: Colors.black.withValues(
                                                  alpha: 0.5,
                                                ),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                        if (message.message
                                            .trim()
                                            .isNotEmpty) ...<Widget>[
                                          const SizedBox(height: 8),
                                          Text(
                                            message.message,
                                            style: const TextStyle(
                                              height: 1.45,
                                            ),
                                          ),
                                        ],
                                        if (message.attachmentUrl
                                            .trim()
                                            .isNotEmpty) ...<Widget>[
                                          const SizedBox(height: 10),
                                          SelectableText(
                                            message.attachmentUrl,
                                            style: const TextStyle(
                                              color: Color(0xFF8A6424),
                                              fontWeight: FontWeight.w700,
                                            ),
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
                  SafeArea(
                    top: false,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Color(0x12000000),
                            blurRadius: 16,
                            offset: Offset(0, -6),
                          ),
                        ],
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _replyController,
                              minLines: 1,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                hintText: 'Reply to support...',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: _isSendingReply
                                ? null
                                : () => _sendReply(ticket),
                            style: FilledButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.black,
                            ),
                            child: _isSendingReply
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.black,
                                    ),
                                  )
                                : const Text('Send'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
    );
  }
}

class _SupportTicketListTile extends StatelessWidget {
  const _SupportTicketListTile({required this.ticket, required this.onTap});

  final UserSupportTicketSummary ticket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 14,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${ticket.ticketId} • ${ticket.subject}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (ticket.hasUnreadSupportReply)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFB57A2A).withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'New reply',
                        style: TextStyle(
                          color: Color(0xFF8A6424),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                ticket.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.7),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _DetailChip(label: _labelize(ticket.status)),
                  _DetailChip(label: _labelize(ticket.priority)),
                  _DetailChip(label: _labelize(ticket.category)),
                  if (ticket.tripId.isNotEmpty)
                    _DetailChip(label: 'Trip ${ticket.tripId}'),
                  _DetailChip(label: _formatDate(ticket.updatedAt)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupportMetricChip extends StatelessWidget {
  const _SupportMetricChip({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: highlight ? Colors.white : Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.black : Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: highlight
                  ? Colors.black.withValues(alpha: 0.66)
                  : Colors.white.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F1EA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF6F6557),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SupportStateCard extends StatelessWidget {
  const _SupportStateCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.isLoading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 18,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFFB57A2A).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Color(0xFFB57A2A),
                        ),
                      )
                    : Icon(icon, color: const Color(0xFFB57A2A), size: 28),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(
                  color: Colors.black.withValues(alpha: 0.66),
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: onAction,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB57A2A),
                    foregroundColor: Colors.black,
                  ),
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _labelize(String value) {
  final normalized = value.trim().replaceAll('_', ' ');
  if (normalized.isEmpty) {
    return 'Unknown';
  }
  return normalized
      .split(' ')
      .where((String part) => part.isNotEmpty)
      .map((String part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

String _formatDate(DateTime? value) {
  if (value == null) {
    return 'Pending';
  }
  return DateFormat('dd MMM, hh:mm a').format(value.toLocal());
}
