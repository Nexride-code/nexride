import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../admin/admin_config.dart';
import '../../admin/utils/admin_formatters.dart';
import '../../admin/widgets/admin_components.dart';
import '../models/support_models.dart';
import '../support_config.dart';
import '../services/support_attachment_upload_service.dart';
import '../services/support_auth_service.dart';
import '../services/support_ticket_service.dart';

class SupportWorkspaceScreen extends StatefulWidget {
  const SupportWorkspaceScreen({
    required this.session,
    super.key,
    this.authService,
    this.ticketService,
    this.attachmentUploadService,
    this.embeddedInAdmin = false,
    this.initialView = SupportInboxView.dashboard,
    this.initialTicketDocumentId,
    this.routeForView,
    this.routeForTicket,
    this.loginRoute = SupportRoutePaths.login,
  });

  final SupportSession session;
  final SupportAuthService? authService;
  final SupportTicketService? ticketService;
  final SupportAttachmentUploadService? attachmentUploadService;
  final bool embeddedInAdmin;
  final SupportInboxView initialView;
  final String? initialTicketDocumentId;
  final String Function(SupportInboxView view)? routeForView;
  final String Function(String ticketDocumentId)? routeForTicket;
  final String loginRoute;

  @override
  State<SupportWorkspaceScreen> createState() => _SupportWorkspaceScreenState();
}

class _SupportWorkspaceScreenState extends State<SupportWorkspaceScreen> {
  late final SupportTicketService _ticketService;
  late final SupportAttachmentUploadService _attachmentUploadService;
  late final SupportAuthService? _authService;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _tripFilterController = TextEditingController();
  final TextEditingController _replyController = TextEditingController();
  final TextEditingController _resolutionController = TextEditingController();

  SupportPortalSnapshot? _snapshot;
  SupportTicketDetail? _selectedDetail;
  SupportInboxView _view = SupportInboxView.dashboard;
  String? _selectedTicketDocumentId;
  String? _errorMessage;
  String? _detailErrorMessage;
  bool _isLoading = true;
  bool _isLoadingDetail = false;
  bool _isSubmittingAction = false;
  bool _tokenRefreshedForDashboardLoad = false;
  String _creatorTypeFilter = 'All';
  String _priorityFilter = 'All';
  String _statusFilter = 'All';
  String _categoryFilter = 'All';
  String _replyVisibility = 'public';
  String? _statusDraft;
  String? _assigneeDraft;
  SupportAttachmentSelection? _selectedAttachment;
  double? _uploadProgress;
  Map<String, dynamic>? _merchantOrderContextPayload;
  String? _merchantOrderContextError;
  bool _merchantOrderContextLoading = false;

  @override
  void initState() {
    super.initState();
    _ticketService = widget.ticketService ?? SupportTicketService();
    _attachmentUploadService = widget.attachmentUploadService ??
        const SupportAttachmentUploadService();
    _authService = widget.authService;
    _view = widget.initialTicketDocumentId != null
        ? SupportInboxView.open
        : widget.initialView;
    _selectedTicketDocumentId = widget.initialTicketDocumentId;
    unawaited(_loadSnapshot());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tripFilterController.dispose();
    _replyController.dispose();
    _resolutionController.dispose();
    super.dispose();
  }

  Future<void> _loadSnapshot() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      if (!_tokenRefreshedForDashboardLoad) {
        if (_authService != null) {
          await _authService.forceTokenRefresh();
        } else {
          await FirebaseAuth.instance.currentUser?.getIdToken(true);
        }
        _tokenRefreshedForDashboardLoad = true;
      }
      await _ticketService.touchStaffPresence(session: widget.session);
      final snapshot = await _ticketService.fetchPortalSnapshot(
        session: widget.session,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
      });
      final initialTicket = _selectedTicketDocumentId;
      if (initialTicket != null) {
        await _selectTicket(initialTicket, updateRoute: false);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = _friendlySupportLoadFailureMessage(error);
      });
    }
  }

  Future<void> _selectTicket(
    String ticketDocumentId, {
    bool updateRoute = true,
  }) async {
    if (mounted) {
      setState(() {
        _selectedTicketDocumentId = ticketDocumentId;
        _isLoadingDetail = true;
        _detailErrorMessage = null;
        _merchantOrderContextPayload = null;
        _merchantOrderContextError = null;
        _merchantOrderContextLoading = false;
        if (_view == SupportInboxView.dashboard) {
          _view = SupportInboxView.open;
        }
      });
    }

    try {
      await _ticketService.markTicketViewed(
        ticketDocumentId: ticketDocumentId,
        viewerId: widget.session.uid,
      );
      final detail = await _ticketService.fetchTicketDetail(
        ticketDocumentId: ticketDocumentId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedDetail = detail;
        _statusDraft = detail.ticket.status;
        _assigneeDraft = detail.ticket.assignedToStaffId;
        _isLoadingDetail = false;
      });
      if (updateRoute) {
        _updateRouteForTicket(ticketDocumentId);
      }
      unawaited(_loadSnapshot());
      unawaited(_loadMerchantOrderContext(detail.ticket));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingDetail = false;
        _detailErrorMessage = _friendlySupportDetailFailureMessage(error);
      });
    }
  }

  Future<void> _loadMerchantOrderContext(SupportTicketSummary ticket) async {
    final raw = ticket.rawData;
    final oid =
        (raw['merchant_order_id'] ?? raw['merchantOrderId'])?.toString().trim() ??
            '';
    if (oid.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _merchantOrderContextLoading = true;
        _merchantOrderContextError = null;
        _merchantOrderContextPayload = null;
      });
    }
    try {
      final r = await _ticketService.fetchMerchantOrderContext(orderId: oid);
      if (!mounted) {
        return;
      }
      if (r['success'] == true) {
        setState(() {
          _merchantOrderContextPayload = r;
          _merchantOrderContextLoading = false;
        });
      } else {
        setState(() {
          _merchantOrderContextError = r['reason']?.toString() ?? 'load_failed';
          _merchantOrderContextLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _merchantOrderContextError = e.toString();
        _merchantOrderContextLoading = false;
      });
    }
  }

  String _friendlySupportLoadFailureMessage(Object error) {
    if (_isPermissionDenied(error)) {
      return 'Your account is signed in but does not have access. Contact the NexRide system administrator.';
    }
    return 'We could not load the support queue right now. Please retry in a moment.';
  }

  String _friendlySupportDetailFailureMessage(Object error) {
    if (_isPermissionDenied(error)) {
      return 'Your account is signed in but does not have access. Contact the NexRide system administrator.';
    }
    return 'The selected ticket could not be loaded. Try refreshing and opening it again.';
  }

  bool _isPermissionDenied(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('permission-denied') ||
        message.contains('permission denied');
  }

  Future<void> _logout() async {
    await _authService?.signOut();
    if (!mounted || widget.embeddedInAdmin) {
      return;
    }
    Navigator.of(context).pushNamedAndRemoveUntil(
      widget.loginRoute,
      (Route<dynamic> route) => false,
    );
  }

  void _updateRouteForView(SupportInboxView view) {
    final path = widget.routeForView?.call(view);
    if (path == null || !kIsWeb) {
      return;
    }
    SystemNavigator.routeInformationUpdated(uri: Uri.parse(path));
  }

  void _updateRouteForTicket(String ticketDocumentId) {
    final path = widget.routeForTicket?.call(ticketDocumentId);
    if (path == null || !kIsWeb) {
      return;
    }
    SystemNavigator.routeInformationUpdated(uri: Uri.parse(path));
  }

  void _selectView(SupportInboxView view) {
    setState(() {
      _view = view;
      if (view != SupportInboxView.open) {
        _selectedTicketDocumentId = null;
        _selectedDetail = null;
      }
    });
    _updateRouteForView(view);
  }

  List<SupportTicketSummary> get _filteredTickets {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const <SupportTicketSummary>[];
    }

    final query = _searchController.text.trim().toLowerCase();
    final tickets = snapshot.tickets.where((SupportTicketSummary ticket) {
      final matchesView = switch (_view) {
        SupportInboxView.dashboard => true,
        SupportInboxView.open =>
          ticket.status != 'resolved' && ticket.status != 'closed',
        SupportInboxView.assignedToMe =>
          ticket.assignedToStaffId == widget.session.uid &&
              ticket.status != 'resolved' &&
              ticket.status != 'closed',
        SupportInboxView.pendingUser => ticket.status == 'pending_user',
        SupportInboxView.escalated =>
          ticket.escalated || ticket.status == 'escalated',
        SupportInboxView.resolved => ticket.isResolved,
      };

      final tripQuery = _tripFilterController.text.trim().toLowerCase();
      final matchesCreatorType = _creatorTypeFilter == 'All' ||
          ticket.createdByType == _creatorTypeFilter;
      final matchesPriority =
          _priorityFilter == 'All' || ticket.priority == _priorityFilter;
      final matchesStatus =
          _statusFilter == 'All' || ticket.status == _statusFilter;
      final matchesCategory =
          _categoryFilter == 'All' || ticket.category == _categoryFilter;
      final matchesTrip =
          tripQuery.isEmpty || ticket.tripId.toLowerCase().contains(tripQuery);
      final matchesQuery = query.isEmpty ||
          ticket.ticketId.toLowerCase().contains(query) ||
          ticket.subject.toLowerCase().contains(query) ||
          ticket.message.toLowerCase().contains(query) ||
          ticket.tripId.toLowerCase().contains(query) ||
          ticket.requesterProfile.name.toLowerCase().contains(query) ||
          ticket.counterpartyProfile.name.toLowerCase().contains(query) ||
          ticket.tags.any((String tag) => tag.toLowerCase().contains(query));

      return matchesView &&
          matchesCreatorType &&
          matchesPriority &&
          matchesStatus &&
          matchesCategory &&
          matchesTrip &&
          matchesQuery;
    }).toList();

    tickets.sort(
      (SupportTicketSummary a, SupportTicketSummary b) =>
          (b.updatedAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0),
    );
    return tickets;
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: const <String>[
        'jpg',
        'jpeg',
        'png',
        'pdf',
        'txt',
      ],
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    final file = result.files.single;
    if (file.bytes == null) {
      _showSnack('We could not read the selected attachment.');
      return;
    }
    setState(() {
      _selectedAttachment = SupportAttachmentSelection(
        fileName: file.name,
        mimeType: _mimeTypeForFileName(file.name),
        fileSizeBytes: file.size,
        bytes: file.bytes!,
      );
    });
  }

  Future<void> _sendReply() async {
    final detail = _selectedDetail;
    if (detail == null || _isSubmittingAction) {
      return;
    }
    setState(() {
      _isSubmittingAction = true;
      _uploadProgress = null;
    });

    try {
      var attachmentUrl = '';
      final selectedAttachment = _selectedAttachment;
      if (selectedAttachment != null) {
        final uploaded = await _attachmentUploadService.uploadAttachment(
          ticketDocumentId: detail.ticket.documentId,
          actorId: widget.session.uid,
          asset: selectedAttachment,
          onProgress: (double progress) {
            if (!mounted) {
              return;
            }
            setState(() {
              _uploadProgress = progress;
            });
          },
        );
        attachmentUrl = uploaded.fileUrl;
      }

      await _ticketService.addReply(
        ticketDocumentId: detail.ticket.documentId,
        actor: widget.session,
        message: _replyController.text,
        visibility: _replyVisibility,
        attachmentUrl: attachmentUrl,
      );
      _replyController.clear();
      _selectedAttachment = null;
      _uploadProgress = null;
      _showSnack(
        _replyVisibility == 'internal'
            ? 'Internal note saved.'
            : 'Public reply sent.',
      );
      await _selectTicket(detail.ticket.documentId, updateRoute: false);
      await _loadSnapshot();
    } catch (error) {
      _showSnack('We could not send that reply right now.');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingAction = false;
          _uploadProgress = null;
        });
      }
    }
  }

  Future<void> _assignSelectedTicket() async {
    final detail = _selectedDetail;
    final snapshot = _snapshot;
    final assigneeId = _assigneeDraft;
    if (detail == null ||
        snapshot == null ||
        assigneeId == null ||
        assigneeId.isEmpty) {
      return;
    }
    final assignee = snapshot.staff.firstWhere(
      (SupportStaffRecord staff) => staff.uid == assigneeId,
      orElse: () => SupportStaffRecord(
        uid: assigneeId,
        displayName: 'Support staff',
        email: '',
        role: 'support_agent',
        enabled: true,
        lastActiveAt: null,
        rawData: const <String, dynamic>{},
      ),
    );
    await _runTicketAction(
      () => _ticketService.assignTicket(
        ticketDocumentId: detail.ticket.documentId,
        actor: widget.session,
        assignee: assignee,
      ),
      successMessage: 'Ticket assignment updated.',
    );
  }

  Future<void> _applyStatusChange() async {
    final detail = _selectedDetail;
    final status = _statusDraft;
    if (detail == null || status == null || status.isEmpty) {
      return;
    }
    await _runTicketAction(
      () => _ticketService.updateStatus(
        ticketDocumentId: detail.ticket.documentId,
        actor: widget.session,
        status: status,
        resolution: _resolutionController.text,
      ),
      successMessage: 'Ticket status updated.',
    );
  }

  Future<void> _markPendingUser() async {
    final detail = _selectedDetail;
    if (detail == null) {
      return;
    }
    setState(() {
      _statusDraft = 'pending_user';
    });
    await _applyStatusChange();
  }

  Future<void> _resolveTicket() async {
    final detail = _selectedDetail;
    if (detail == null) {
      return;
    }
    setState(() {
      _statusDraft = 'resolved';
    });
    await _applyStatusChange();
  }

  Future<void> _closeTicket() async {
    final detail = _selectedDetail;
    if (detail == null) {
      return;
    }
    setState(() {
      _statusDraft = 'closed';
    });
    await _applyStatusChange();
  }

  Future<void> _escalateTicket() async {
    final detail = _selectedDetail;
    if (detail == null) {
      return;
    }
    await _runTicketAction(
      () => _ticketService.escalateTicket(
        ticketDocumentId: detail.ticket.documentId,
        actor: widget.session,
      ),
      successMessage: 'Ticket escalated.',
    );
  }

  Future<void> _runTicketAction(
    Future<void> Function() action, {
    required String successMessage,
  }) async {
    if (_isSubmittingAction) {
      return;
    }
    setState(() {
      _isSubmittingAction = true;
    });
    try {
      await action();
      _showSnack(successMessage);
      final ticketId = _selectedDetail?.ticket.documentId;
      if (ticketId != null) {
        await _selectTicket(ticketId, updateRoute: false);
      }
      await _loadSnapshot();
    } catch (_) {
      _showSnack('That support action could not be completed right now.');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmittingAction = false;
        });
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embeddedInAdmin) {
      return _buildContent(
        showDrawerButton: false,
        compact: MediaQuery.sizeOf(context).width < 920,
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final wide = constraints.maxWidth >= 1180;
        final compact = constraints.maxWidth < 920;
        final navigation = _buildNavigationPanel(compact: compact);

        if (wide) {
          return Scaffold(
            backgroundColor: AdminThemeTokens.canvas,
            body: SafeArea(
              child: Row(
                children: <Widget>[
                  SizedBox(width: 280, child: navigation),
                  Expanded(
                    child: _buildContent(
                      showDrawerButton: false,
                      compact: compact,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          backgroundColor: AdminThemeTokens.canvas,
          drawer: Drawer(
            width: 280,
            child: SafeArea(child: navigation),
          ),
          body: SafeArea(
            child: _buildContent(
              showDrawerButton: true,
              compact: compact,
            ),
          ),
        );
      },
    );
  }

  Widget _buildNavigationPanel({
    required bool compact,
  }) {
    final analytics = _snapshot?.analytics;
    return Container(
      color: const Color(0xFF171A1D),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AdminThemeTokens.gold.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.support_agent_rounded,
                    color: AdminThemeTokens.gold,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'NexRide Support',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.session.displayName,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          for (final view in SupportInboxView.values) ...<Widget>[
            _SupportNavTile(
              label: view.label,
              icon: view.icon,
              selected: _view == view,
              badge: _badgeForView(view, analytics),
              onTap: () {
                if (compact && !widget.embeddedInAdmin) {
                  Navigator.of(context).pop();
                }
                _selectView(view);
              },
            ),
            const SizedBox(height: 8),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  normalizeSupportRole(widget.session.role)
                      .replaceAll('_', ' ')
                      .toUpperCase(),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.session.accessMode.replaceAll('_', ' '),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    height: 1.4,
                  ),
                ),
                if (!widget.embeddedInAdmin) ...<Widget>[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _logout,
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('Sign out'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent({
    required bool showDrawerButton,
    required bool compact,
  }) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: AdminThemeTokens.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (showDrawerButton)
                  Builder(
                    builder: (BuildContext innerContext) {
                      return IconButton(
                        onPressed: () => Scaffold.of(innerContext).openDrawer(),
                        icon: const Icon(Icons.menu_rounded),
                      );
                    },
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'NexRide Support',
                        style: TextStyle(
                          color: AdminThemeTokens.gold,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _view.label,
                        style: const TextStyle(
                          color: AdminThemeTokens.ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.embeddedInAdmin
                            ? 'Shared support ticket system with admin override controls, staff audit visibility, and response-time monitoring.'
                            : 'Dedicated support workspace for complaints, disputes, reports, ticket replies, assignments, and escalations.',
                        style: const TextStyle(
                          color: Color(0xFF6D675D),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6F1E5),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        '${widget.session.displayName} • ${sentenceCaseStatus(widget.session.role)}',
                        style: const TextStyle(
                          color: Color(0xFF6E675C),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    AdminGhostButton(
                      label: 'Refresh',
                      icon: Icons.refresh_rounded,
                      onPressed: _loadSnapshot,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: _buildBody(compact: compact),
          ),
        ),
      ],
    );
  }

  Widget _buildBody({
    required bool compact,
  }) {
    if (_snapshot == null && _isLoading) {
      return const AdminEmptyState(
        title: 'Loading support workspace',
        message:
            'NexRide Support is retrieving tickets, staff assignments, and activity logs.',
        icon: Icons.sync_rounded,
      );
    }

    if (_snapshot == null) {
      return AdminSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _errorMessage ?? 'The support workspace could not be loaded.',
              style: const TextStyle(
                color: AdminThemeTokens.ink,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            AdminPrimaryButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: _loadSnapshot,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (_errorMessage?.trim().isNotEmpty ?? false) ...<Widget>[
            _buildInlineNotice(_errorMessage!),
            const SizedBox(height: 16),
          ],
          if (_view == SupportInboxView.dashboard)
            _buildDashboardView(compact: compact)
          else
            _buildQueueView(compact: compact),
        ],
      ),
    );
  }

  Widget _buildDashboardView({
    required bool compact,
  }) {
    final snapshot = _snapshot!;
    final analytics = snapshot.analytics;
    final overdueTickets =
        snapshot.tickets.where((SupportTicketSummary t) => t.isOverdue).take(4);
    final urgentTickets = snapshot.tickets
        .where(
          (SupportTicketSummary t) =>
              !t.isResolved && (t.priority == 'urgent' || t.priority == 'high'),
        )
        .take(4);
    final assignedToMe = snapshot.tickets
        .where((SupportTicketSummary t) =>
            t.assignedToStaffId == widget.session.uid)
        .take(4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildMetricWrap(
          compact: compact,
          cards: <Widget>[
            _SupportMetricCard(
              label: 'Open tickets',
              value: analytics.openTickets.toString(),
              caption: 'All active rider and driver cases still in progress.',
              icon: Icons.inbox_outlined,
            ),
            _SupportMetricCard(
              label: 'Assigned to me',
              value: analytics.assignedToMe.toString(),
              caption: 'Cases currently routed to your support queue.',
              icon: Icons.assignment_ind_outlined,
            ),
            _SupportMetricCard(
              label: 'Pending user',
              value: analytics.pendingUserTickets.toString(),
              caption:
                  'Tickets waiting on the rider or driver to send a follow-up reply.',
              icon: Icons.hourglass_top_rounded,
            ),
            _SupportMetricCard(
              label: 'Escalated',
              value: analytics.escalatedTickets.toString(),
              caption: 'Tickets needing manager or admin intervention.',
              icon: Icons.priority_high_rounded,
            ),
            _SupportMetricCard(
              label: 'Unread replies',
              value: analytics.unreadReplies.toString(),
              caption:
                  'Tickets with new rider or driver replies since you last viewed them.',
              icon: Icons.mark_email_unread_outlined,
            ),
            _SupportMetricCard(
              label: 'Overdue',
              value: analytics.overdueTickets.toString(),
              caption: 'Active tickets that are outside their SLA target.',
              icon: Icons.timer_off_outlined,
            ),
            if (widget.session.permissions.canViewSupportAnalytics)
              _SupportMetricCard(
                label: 'Avg first response',
                value: analytics.averageFirstResponseMinutes <= 0
                    ? '0m'
                    : '${analytics.averageFirstResponseMinutes.toStringAsFixed(0)}m',
                caption:
                    'Average time from ticket creation to first staff reply.',
                icon: Icons.speed_outlined,
              ),
          ],
        ),
        const SizedBox(height: 20),
        _buildDashboardGroups(
          compact: compact,
          left: _buildTicketGroupCard(
            title: 'Overdue warnings',
            tickets: overdueTickets.toList(),
            emptyMessage:
                'No tickets are overdue right now. SLA timers are currently healthy.',
          ),
          right: _buildTicketGroupCard(
            title: 'High-priority queue',
            tickets: urgentTickets.toList(),
            emptyMessage:
                'No high-priority or urgent complaints are waiting at the moment.',
          ),
        ),
        const SizedBox(height: 20),
        _buildDashboardGroups(
          compact: compact,
          left: _buildTicketGroupCard(
            title: 'Assigned to me',
            tickets: assignedToMe.toList(),
            emptyMessage:
                'You do not have assigned tickets right now. Open cases are ready for pickup.',
          ),
          right: widget.session.permissions.canAuditStaffActions
              ? _buildActivityCard(
                  title: 'Staff activity audit',
                  logs: snapshot.logs.take(6).toList(),
                )
              : _buildTicketGroupCard(
                  title: 'Recent tickets',
                  tickets: snapshot.tickets.take(4).toList(),
                  emptyMessage:
                      'Tickets will appear here as soon as riders or drivers submit new reports.',
                ),
        ),
      ],
    );
  }

  Widget _buildQueueView({
    required bool compact,
  }) {
    final tickets = _filteredTickets;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildFilterBar(),
        const SizedBox(height: 16),
        if (tickets.isEmpty)
          const AdminEmptyState(
            title: 'No tickets in this queue',
            message:
                'This queue is clear right now. When new complaints, disputes, or reports arrive, they will show up here with SLA timing and assignment status.',
            icon: Icons.inbox_outlined,
          )
        else if (compact)
          _selectedTicketDocumentId == null
              ? _buildTicketListCard(tickets)
              : _buildTicketDetailPanel(compact: true)
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 5,
                child: _buildTicketListCard(tickets),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 7,
                child: _buildTicketDetailPanel(compact: false),
              ),
            ],
          ),
      ],
    );
    return content;
  }

  Widget _buildFilterBar() {
    final tickets = _snapshot?.tickets ?? const <SupportTicketSummary>[];
    final priorities = <String>{
      'All',
      ...tickets.map((SupportTicketSummary t) => t.priority)
    };
    final creatorTypes = <String>{
      'All',
      ...tickets.map((SupportTicketSummary t) => t.createdByType)
    };
    final statuses = <String>{
      'All',
      ...tickets.map((SupportTicketSummary t) => t.status)
    };
    final categories = <String>{
      'All',
      ...tickets.map((SupportTicketSummary t) => t.category)
    };
    final priorityValue =
        priorities.contains(_priorityFilter) ? _priorityFilter : 'All';
    final creatorTypeValue =
        creatorTypes.contains(_creatorTypeFilter) ? _creatorTypeFilter : 'All';
    final statusValue =
        statuses.contains(_statusFilter) ? _statusFilter : 'All';
    final categoryValue =
        categories.contains(_categoryFilter) ? _categoryFilter : 'All';

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        SizedBox(
          width: 320,
          child: AdminTextFilterField(
            controller: _searchController,
            hintText: 'Search ticket, user, trip, subject, or tag',
            onChanged: (_) => setState(() {}),
          ),
        ),
        SizedBox(
          width: 220,
          child: AdminTextFilterField(
            controller: _tripFilterController,
            hintText: 'Filter by trip ID',
            onChanged: (_) => setState(() {}),
          ),
        ),
        SizedBox(
          width: 180,
          child: AdminFilterDropdown<String>(
            value: creatorTypeValue,
            items: creatorTypes
                .map(
                  (String value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(sentenceCaseStatus(value)),
                  ),
                )
                .toList(),
            onChanged: (String? value) => setState(() {
              _creatorTypeFilter = value ?? 'All';
            }),
          ),
        ),
        SizedBox(
          width: 180,
          child: AdminFilterDropdown<String>(
            value: priorityValue,
            items: priorities
                .map(
                  (String value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(sentenceCaseStatus(value)),
                  ),
                )
                .toList(),
            onChanged: (String? value) => setState(() {
              _priorityFilter = value ?? 'All';
            }),
          ),
        ),
        SizedBox(
          width: 200,
          child: AdminFilterDropdown<String>(
            value: statusValue,
            items: statuses
                .map(
                  (String value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(sentenceCaseStatus(value)),
                  ),
                )
                .toList(),
            onChanged: (String? value) => setState(() {
              _statusFilter = value ?? 'All';
            }),
          ),
        ),
        SizedBox(
          width: 200,
          child: AdminFilterDropdown<String>(
            value: categoryValue,
            items: categories
                .map(
                  (String value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(sentenceCaseStatus(value)),
                  ),
                )
                .toList(),
            onChanged: (String? value) => setState(() {
              _categoryFilter = value ?? 'All';
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildTicketListCard(List<SupportTicketSummary> tickets) {
    return AdminSurfaceCard(
      padding: const EdgeInsets.all(0),
      child: Column(
        children: <Widget>[
          for (var index = 0; index < tickets.length; index++) ...<Widget>[
            _buildTicketListTile(tickets[index]),
            if (index != tickets.length - 1)
              const Divider(height: 1, color: AdminThemeTokens.border),
          ],
        ],
      ),
    );
  }

  Widget _buildTicketListTile(SupportTicketSummary ticket) {
    final selected = ticket.documentId == _selectedTicketDocumentId;
    final unread = ticket.hasUnreadExternalReply(widget.session.uid);
    return InkWell(
      onTap: () => _selectTicket(ticket.documentId),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF7F2E6) : Colors.transparent,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${ticket.ticketId} • ${ticket.subject}',
                    style: const TextStyle(
                      color: AdminThemeTokens.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (unread)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6F2FF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'New reply',
                      style: TextStyle(
                        color: Color(0xFF2F6DA8),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${ticket.requesterProfile.name} (${sentenceCaseStatus(ticket.createdByType)}) vs ${ticket.counterpartyProfile.name}',
              style: const TextStyle(
                color: Color(0xFF746E62),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                AdminStatusChip(ticket.status),
                AdminStatusChip(
                  ticket.priority,
                  color: _priorityColor(ticket.priority),
                ),
                if (ticket.escalated)
                  const AdminStatusChip(
                    'Escalated',
                    color: Color(0xFFCF5C36),
                  ),
                if (ticket.isOverdue)
                  const AdminStatusChip(
                    'Overdue',
                    color: Color(0xFFCF5C36),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              ticket.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.66),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: <Widget>[
                _metaText(
                    'Trip', ticket.tripId.isEmpty ? 'N/A' : ticket.tripId),
                _metaText(
                  'Aging',
                  _formatAge(ticket.age),
                ),
                _metaText(
                  'Assignee',
                  ticket.assignedToStaffName.isEmpty
                      ? 'Unassigned'
                      : ticket.assignedToStaffName,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketDetailPanel({
    required bool compact,
  }) {
    final selectedId = _selectedTicketDocumentId;
    if (selectedId == null) {
      return const AdminEmptyState(
        title: 'Select a ticket',
        message:
            'Choose a complaint or dispute from the queue to open its conversation thread, user snapshot, trip context, and ticket actions.',
        icon: Icons.mark_email_read_outlined,
      );
    }

    if (_isLoadingDetail) {
      return const AdminEmptyState(
        title: 'Loading ticket detail',
        message:
            'Fetching the conversation thread, trip snapshot, and activity history for this ticket.',
        icon: Icons.sync_rounded,
      );
    }

    if (_selectedDetail == null) {
      return AdminSurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _detailErrorMessage ??
                  'This ticket detail could not be loaded right now.',
              style: const TextStyle(
                color: AdminThemeTokens.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            AdminPrimaryButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onPressed: () => _selectTicket(selectedId, updateRoute: false),
            ),
          ],
        ),
      );
    }

    final detail = _selectedDetail!;
    final ticket = detail.ticket;
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (compact)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _selectedTicketDocumentId = null;
                  _selectedDetail = null;
                  _updateRouteForView(_view);
                }),
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('Back to queue'),
              ),
            ),
          Text(
            '${ticket.ticketId} • ${ticket.subject}',
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              AdminStatusChip(ticket.status),
              AdminStatusChip(
                ticket.priority,
                color: _priorityColor(ticket.priority),
              ),
              AdminStatusChip(ticket.category),
              if (ticket.escalated)
                const AdminStatusChip(
                  'Escalated',
                  color: Color(0xFFCF5C36),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Created ${formatAdminDateTime(ticket.createdAt)} • Last reply ${formatAdminDateTime(ticket.lastReplyAt)}',
            style: const TextStyle(
              color: Color(0xFF6D685F),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          _buildActionRow(ticket),
          const SizedBox(height: 18),
          _buildSupportMetadataRow(ticket),
          const SizedBox(height: 18),
          _buildMerchantCommerceContext(ticket),
          const SizedBox(height: 18),
          _buildDetailResponsiveRow(
            compact: compact,
            left: _buildParticipantSnapshotCard(
              title: 'User profile snapshot',
              primary: ticket.requesterProfile,
              secondary: ticket.counterpartyProfile,
            ),
            right: _buildTripDetailCard(ticket.tripSnapshot),
          ),
          const SizedBox(height: 18),
          _buildConversationCard(detail),
          const SizedBox(height: 18),
          _buildComposerCard(ticket),
          if (widget.session.permissions.canAuditStaffActions) ...<Widget>[
            const SizedBox(height: 18),
            _buildActivityCard(
              title: 'Ticket activity',
              logs: detail.logs,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionRow(SupportTicketSummary ticket) {
    final canAssign = widget.session.permissions.canAssignTickets;
    final canEscalate = widget.session.permissions.canEscalateTickets;
    final canStatus = widget.session.permissions.canUpdateTicketStatus;
    final staff = _snapshot?.staff ?? const <SupportStaffRecord>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            if (canStatus)
              AdminGhostButton(
                label: 'Pending user',
                icon: Icons.hourglass_top_rounded,
                onPressed: _markPendingUser,
              ),
            if (canStatus)
              AdminPrimaryButton(
                label: 'Resolve',
                icon: Icons.task_alt_rounded,
                onPressed: _resolveTicket,
                compact: true,
              ),
            if (canStatus)
              AdminGhostButton(
                label: 'Close',
                icon: Icons.inventory_2_outlined,
                onPressed: _closeTicket,
              ),
            if (canEscalate && !ticket.escalated)
              AdminGhostButton(
                label: 'Escalate',
                icon: Icons.priority_high_rounded,
                onPressed: _escalateTicket,
              ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            if (canAssign)
              SizedBox(
                width: 250,
                child: AdminFilterDropdown<String>(
                  key: ValueKey<String>(
                      'assign-${ticket.documentId}-${_assigneeDraft ?? ''}'),
                  value: (_assigneeDraft == null || _assigneeDraft!.isEmpty) &&
                          staff.isNotEmpty
                      ? 'unassigned'
                      : (_assigneeDraft ?? 'unassigned'),
                  items: <DropdownMenuItem<String>>[
                    const DropdownMenuItem<String>(
                      value: 'unassigned',
                      child: Text('Unassigned'),
                    ),
                    ...staff.map(
                      (SupportStaffRecord staffRecord) =>
                          DropdownMenuItem<String>(
                        value: staffRecord.uid,
                        child: Text(
                          '${staffRecord.displayName} • ${sentenceCaseStatus(staffRecord.role)}',
                        ),
                      ),
                    ),
                  ],
                  onChanged: (String? value) => setState(() {
                    _assigneeDraft = value == 'unassigned' ? '' : value;
                  }),
                ),
              ),
            if (canAssign)
              AdminPrimaryButton(
                label: 'Assign ticket',
                icon: Icons.person_add_alt_1_rounded,
                onPressed: _assignSelectedTicket,
                compact: true,
              ),
            if (canStatus)
              SizedBox(
                width: 210,
                child: AdminFilterDropdown<String>(
                  key: ValueKey<String>(
                      'status-${ticket.documentId}-${_statusDraft ?? ''}'),
                  value: _statusDraft ?? ticket.status,
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                        value: 'open', child: Text('Open')),
                    DropdownMenuItem<String>(
                      value: 'pending_user',
                      child: Text('Pending user'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'escalated',
                      child: Text('Escalated'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'resolved',
                      child: Text('Resolved'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'closed',
                      child: Text('Closed'),
                    ),
                  ],
                  onChanged: (String? value) => setState(() {
                    _statusDraft = value ?? ticket.status;
                  }),
                ),
              ),
            if (canStatus)
              AdminGhostButton(
                label: 'Apply status',
                icon: Icons.publish_rounded,
                onPressed: _applyStatusChange,
              ),
          ],
        ),
        if (canStatus) ...<Widget>[
          const SizedBox(height: 14),
          TextField(
            controller: _resolutionController,
            minLines: 2,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Resolution or status note',
              hintText:
                  'Add the resolution summary or the reason for this status change.',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: AdminThemeTokens.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide:
                    const BorderSide(color: AdminThemeTokens.gold, width: 1.4),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMerchantCommerceContext(SupportTicketSummary ticket) {
    final raw = ticket.rawData;
    final oid =
        (raw['merchant_order_id'] ?? raw['merchantOrderId'])?.toString().trim() ??
            '';
    if (oid.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_merchantOrderContextLoading) {
      return const AdminSurfaceCard(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Loading merchant order context…'),
            ],
          ),
        ),
      );
    }
    if (_merchantOrderContextError != null) {
      return AdminSurfaceCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Merchant order lookup failed: ${_merchantOrderContextError!}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    final payload = _merchantOrderContextPayload;
    if (payload == null || payload['success'] != true) {
      return const SizedBox.shrink();
    }
    final order = _mapDynamic(payload['order']);
    final merchant = _mapDynamic(payload['merchant']);
    final lines = <String>[
      'Order: ${order['order_id'] ?? oid}',
      'Status: ${order['order_status'] ?? ''}',
      'Customer: ${order['customer_uid'] ?? ''}',
      'Payment: ${order['payment_status'] ?? ''} · ref ${order['prepaid_flutterwave_ref'] ?? ''}',
      'Total ₦${order['total_ngn'] ?? ''} · commission ₦${order['commission_ngn'] ?? ''}',
      if (merchant.isNotEmpty) 'Merchant: ${merchant['business_name'] ?? merchant['merchant_id']}',
    ];
    return AdminSurfaceCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Merchant / order (support)',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 10),
            ...lines.map((l) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(l, style: const TextStyle(height: 1.35)),
                )),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _mapDynamic(dynamic v) {
    if (v is Map) {
      return v.map((k, dynamic val) => MapEntry(k.toString(), val));
    }
    return <String, dynamic>{};
  }

  Widget _buildSupportMetadataRow(SupportTicketSummary ticket) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        _detailChip('Created by', sentenceCaseStatus(ticket.createdByType)),
        _detailChip('Assigned', ticket.assignedToStaffName),
        _detailChip('Aging', _formatAge(ticket.age)),
        _detailChip('SLA', ticket.isOverdue ? 'Overdue' : 'Within target'),
        if (ticket.tags.isNotEmpty) _detailChip('Tags', ticket.tags.join(', ')),
      ],
    );
  }

  Widget _buildParticipantSnapshotCard({
    required String title,
    required SupportParticipantSnapshot primary,
    required SupportParticipantSnapshot secondary,
  }) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          _participantBlock('Requester', primary),
          const SizedBox(height: 16),
          _participantBlock('Counterparty', secondary),
        ],
      ),
    );
  }

  Widget _participantBlock(
      String label, SupportParticipantSnapshot participant) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5EF),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF7A7367),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            participant.name,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              _metaText('Type', sentenceCaseStatus(participant.userType)),
              _metaText('Status', sentenceCaseStatus(participant.status)),
              _metaText(
                'Verification',
                sentenceCaseStatus(participant.verificationStatus),
              ),
              _metaText(
                  'City', participant.city.isEmpty ? 'N/A' : participant.city),
              _metaText('Phone',
                  participant.phone.isEmpty ? 'N/A' : participant.phone),
              _metaText('Email',
                  participant.email.isEmpty ? 'N/A' : participant.email),
              _metaText(
                'Rating',
                participant.rating <= 0
                    ? 'N/A'
                    : '${participant.rating.toStringAsFixed(1)} (${participant.ratingCount})',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTripDetailCard(SupportTripSnapshot trip) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Trip dispute detail',
            style: TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: <Widget>[
              _detailChip('Trip', trip.tripId.isEmpty ? 'N/A' : trip.tripId),
              _detailChip('Status', sentenceCaseStatus(trip.status)),
              _detailChip('Service', sentenceCaseStatus(trip.serviceType)),
              _detailChip('City', trip.city.isEmpty ? 'N/A' : trip.city),
              _detailChip(
                'Payment',
                trip.paymentMethod.isEmpty
                    ? 'N/A'
                    : sentenceCaseStatus(trip.paymentMethod),
              ),
              _detailChip(
                'Fare',
                trip.fareAmount <= 0
                    ? 'N/A'
                    : formatAdminCurrency(trip.fareAmount),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Pickup: ${trip.pickupAddress.isEmpty ? 'Not recorded' : trip.pickupAddress}',
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 8),
          Text(
            'Destination: ${trip.destinationAddress.isEmpty ? 'Not recorded' : trip.destinationAddress}',
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: <Widget>[
              _metaText('Reason',
                  trip.disputeReason.isEmpty ? 'N/A' : trip.disputeReason),
              _metaText('Source', sentenceCaseStatus(trip.source)),
              _metaText(
                'Distance',
                trip.distanceKm <= 0
                    ? 'N/A'
                    : '${trip.distanceKm.toStringAsFixed(1)} km',
              ),
              _metaText(
                'Duration',
                trip.durationMinutes <= 0
                    ? 'N/A'
                    : '${trip.durationMinutes.toStringAsFixed(0)} min',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConversationCard(SupportTicketDetail detail) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Conversation thread',
            style: TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          if (detail.messages.isEmpty)
            const AdminEmptyState(
              title: 'No replies yet',
              message:
                  'This ticket has the original complaint recorded, but no support reply or internal note has been added yet.',
              icon: Icons.forum_outlined,
            )
          else
            Column(
              children: detail.messages
                  .map((SupportTicketMessage message) =>
                      _buildMessageBubble(message))
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(SupportTicketMessage message) {
    final internal = message.isInternalNote;
    final staffSide = message.senderRole == 'support' ||
        message.senderRole == 'support_manager' ||
        message.senderRole == 'support_agent' ||
        message.senderRole == 'admin' ||
        message.senderRole == 'super_admin';
    return Align(
      alignment: staffSide ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: internal
              ? const Color(0xFFF8F4EC)
              : staffSide
                  ? const Color(0xFFFFF4DE)
                  : const Color(0xFFEFF5FF),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: internal
                ? const Color(0xFFE5D9C5)
                : staffSide
                    ? const Color(0xFFF0D8A6)
                    : const Color(0xFFD8E7FB),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(
                  '${message.senderName} • ${sentenceCaseStatus(message.senderRole)}',
                  style: const TextStyle(
                    color: AdminThemeTokens.ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                AdminStatusChip(
                  internal ? 'Internal note' : 'Public reply',
                  color: internal
                      ? AdminThemeTokens.warning
                      : AdminThemeTokens.info,
                ),
                Text(
                  formatAdminDateTime(message.createdAt),
                  style: const TextStyle(
                    color: Color(0xFF6D685F),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            if (message.message.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                message.message,
                style: const TextStyle(height: 1.5),
              ),
            ],
            if (message.attachmentUrl.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              SelectableText(
                'Attachment: ${message.attachmentUrl}',
                style: const TextStyle(
                  color: AdminThemeTokens.info,
                  decoration: TextDecoration.underline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildComposerCard(SupportTicketSummary ticket) {
    final canReply = widget.session.permissions.canReplyToTickets;
    final canNote = widget.session.permissions.canAddInternalNotes;
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Reply and notes',
            style: TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 180,
                child: AdminFilterDropdown<String>(
                  value: _replyVisibility,
                  items: <DropdownMenuItem<String>>[
                    if (canReply)
                      const DropdownMenuItem<String>(
                        value: 'public',
                        child: Text('Public reply'),
                      ),
                    if (canNote)
                      const DropdownMenuItem<String>(
                        value: 'internal',
                        child: Text('Internal note'),
                      ),
                  ],
                  onChanged: (String? value) => setState(() {
                    _replyVisibility = value ?? 'public';
                  }),
                ),
              ),
              PopupMenuButton<SupportCannedResponse>(
                itemBuilder: (BuildContext context) {
                  return kDefaultSupportCannedResponses
                      .map(
                        (SupportCannedResponse response) =>
                            PopupMenuItem<SupportCannedResponse>(
                          value: response,
                          child: Text(response.label),
                        ),
                      )
                      .toList();
                },
                onSelected: (SupportCannedResponse response) {
                  final current = _replyController.text.trim();
                  _replyController.text = current.isEmpty
                      ? response.body
                      : '$current\n\n${response.body}';
                },
                child: const AdminGhostButton(
                  label: 'Canned responses',
                  icon: Icons.quickreply_outlined,
                  onPressed: null,
                ),
              ),
              AdminGhostButton(
                label: 'Attach file',
                icon: Icons.attach_file_rounded,
                onPressed: _pickAttachment,
              ),
              if (_selectedAttachment != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF6F1E5),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _selectedAttachment!.fileName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: () => setState(() {
                          _selectedAttachment = null;
                        }),
                        child: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _replyController,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: _replyVisibility == 'internal'
                  ? 'Internal note'
                  : 'Public reply',
              hintText: _replyVisibility == 'internal'
                  ? 'Write a staff-only note for audit and collaboration.'
                  : 'Write the response that should be visible to the rider or driver.',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: const BorderSide(color: AdminThemeTokens.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide:
                    const BorderSide(color: AdminThemeTokens.gold, width: 1.4),
              ),
            ),
          ),
          if (_uploadProgress != null) ...<Widget>[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _uploadProgress,
              minHeight: 8,
              borderRadius: BorderRadius.circular(999),
              color: AdminThemeTokens.gold,
              backgroundColor: const Color(0xFFF1E7D1),
            ),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: AdminPrimaryButton(
              label: _replyVisibility == 'internal'
                  ? 'Save internal note'
                  : 'Send public reply',
              icon: Icons.send_rounded,
              onPressed: _isSubmittingAction || (!canReply && !canNote)
                  ? null
                  : _sendReply,
            ),
          ),
          if (ticket.resolution.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F5EF),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                'Resolution: ${ticket.resolution}',
                style: const TextStyle(height: 1.45),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActivityCard({
    required String title,
    required List<SupportActivityLog> logs,
  }) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          if (logs.isEmpty)
            const AdminEmptyState(
              title: 'No staff activity yet',
              message:
                  'Assignments, escalations, replies, and status changes will appear here automatically.',
              icon: Icons.fact_check_outlined,
            )
          else
            Column(
              children: logs.map(_buildLogEntry).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildLogEntry(SupportActivityLog log) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5EF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${log.actorName} • ${sentenceCaseStatus(log.actorRole)}',
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            log.summary,
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 8),
          Text(
            formatAdminDateTime(log.createdAt),
            style: const TextStyle(
              color: Color(0xFF6D685F),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTicketGroupCard({
    required String title,
    required List<SupportTicketSummary> tickets,
    required String emptyMessage,
  }) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 16),
          if (tickets.isEmpty)
            Text(
              emptyMessage,
              style: const TextStyle(
                color: Color(0xFF6D685F),
                height: 1.5,
              ),
            )
          else
            Column(
              children: tickets
                  .map(
                    (SupportTicketSummary ticket) => InkWell(
                      onTap: () => _selectTicket(ticket.documentId),
                      child: Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F5EF),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${ticket.ticketId} • ${ticket.subject}',
                              style: const TextStyle(
                                color: AdminThemeTokens.ink,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              children: <Widget>[
                                AdminStatusChip(ticket.status),
                                AdminStatusChip(
                                  ticket.priority,
                                  color: _priorityColor(ticket.priority),
                                ),
                                _detailChip('Aging', _formatAge(ticket.age)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildMetricWrap({
    required bool compact,
    required List<Widget> cards,
  }) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: cards
          .map(
            (Widget card) => SizedBox(
              width: compact ? double.infinity : 250,
              child: card,
            ),
          )
          .toList(),
    );
  }

  Widget _buildDashboardGroups({
    required bool compact,
    required Widget left,
    required Widget right,
  }) {
    if (compact) {
      return Column(
        children: <Widget>[
          left,
          const SizedBox(height: 16),
          right,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right),
      ],
    );
  }

  Widget _buildDetailResponsiveRow({
    required bool compact,
    required Widget left,
    required Widget right,
  }) {
    if (compact) {
      return Column(
        children: <Widget>[
          left,
          const SizedBox(height: 16),
          right,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: left),
        const SizedBox(width: 16),
        Expanded(child: right),
      ],
    );
  }

  Widget _buildInlineNotice(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6E7),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        message,
        style: const TextStyle(height: 1.45),
      ),
    );
  }

  Widget _detailChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F5EF),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          color: Color(0xFF5E574B),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _metaText(String label, String value) {
    return Text(
      '$label: $value',
      style: const TextStyle(
        color: Color(0xFF5E574B),
        fontWeight: FontWeight.w700,
      ),
    );
  }

  int _badgeForView(SupportInboxView view, SupportAnalytics? analytics) {
    if (analytics == null) {
      return 0;
    }
    return switch (view) {
      SupportInboxView.dashboard => analytics.unreadReplies,
      SupportInboxView.open => analytics.openTickets,
      SupportInboxView.assignedToMe => analytics.assignedToMe,
      SupportInboxView.pendingUser => analytics.pendingUserTickets,
      SupportInboxView.escalated => analytics.escalatedTickets,
      SupportInboxView.resolved => analytics.resolvedTickets,
    };
  }

  Color _priorityColor(String priority) {
    switch (priority.trim().toLowerCase()) {
      case 'urgent':
        return const Color(0xFFCF5C36);
      case 'high':
        return const Color(0xFFB2771A);
      case 'low':
        return const Color(0xFF2B6E6A);
      default:
        return AdminThemeTokens.info;
    }
  }

  String _formatAge(Duration? age) {
    if (age == null) {
      return 'N/A';
    }
    if (age.inDays >= 1) {
      return '${age.inDays}d ${age.inHours.remainder(24)}h';
    }
    if (age.inHours >= 1) {
      return '${age.inHours}h ${age.inMinutes.remainder(60)}m';
    }
    return '${age.inMinutes}m';
  }

  String _mimeTypeForFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.txt')) {
      return 'text/plain';
    }
    return 'image/jpeg';
  }
}

class _SupportNavTile extends StatelessWidget {
  const _SupportNavTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              color: selected
                  ? AdminThemeTokens.gold
                  : Colors.white.withValues(alpha: 0.78),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.82),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AdminThemeTokens.gold.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$badge',
                  style: const TextStyle(
                    color: AdminThemeTokens.gold,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SupportMetricCard extends StatelessWidget {
  const _SupportMetricCard({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AdminThemeTokens.goldSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: AdminThemeTokens.gold),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF68635A),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              color: AdminThemeTokens.ink,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 0.95,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            style: const TextStyle(
              color: Color(0xFF8D8578),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
