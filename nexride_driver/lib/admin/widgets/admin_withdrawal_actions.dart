import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../admin_rbac.dart';
import 'admin_components.dart';

/// Row-level controls for a single withdrawal request.
///
/// Pending requests show explicit "Mark Paid" / "Reject" buttons that open a
/// validation dialog. Any non-pending status (paid, rejected, processing,
/// failed) renders a read-only status badge — no actions.
///
/// The widget is intentionally decoupled from the data service: callers inject
/// [onMarkPaid] (receives the payout reference) and [onReject] (receives the
/// rejection reason) so it can be widget-tested in isolation.
class AdminWithdrawalActions extends StatelessWidget {
  const AdminWithdrawalActions({
    required this.status,
    required this.canApprove,
    required this.onMarkPaid,
    required this.onReject,
    super.key,
  });

  final String status;
  final bool canApprove;
  final Future<void> Function(String payoutReference) onMarkPaid;
  final Future<void> Function(String reason) onReject;

  bool get _isPending => status.trim().toLowerCase() == 'pending';

  @override
  Widget build(BuildContext context) {
    if (!_isPending) {
      return AdminStatusChip(status);
    }

    final Widget markPaid = ElevatedButton(
      key: const Key('withdrawal_mark_paid_button'),
      onPressed: canApprove ? () => _promptMarkPaid(context) : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: AdminThemeTokens.gold,
        foregroundColor: Colors.black,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
      child: const Text('Mark Paid'),
    );

    final Widget reject = OutlinedButton(
      key: const Key('withdrawal_reject_button'),
      onPressed: canApprove ? () => _promptReject(context) : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: AdminThemeTokens.danger,
        side: const BorderSide(color: AdminThemeTokens.danger),
      ),
      child: const Text('Reject'),
    );

    final Widget controls = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[markPaid, reject],
    );

    if (canApprove) {
      return controls;
    }
    return Tooltip(
      message: kAdminNoPermissionTooltip,
      child: controls,
    );
  }

  Future<void> _promptMarkPaid(BuildContext context) async {
    final String? reference = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _RequiredTextDialog(
        title: 'Mark withdrawal as paid',
        label: 'Payout reference',
        hintText: 'Bank transfer / payout reference',
        confirmLabel: 'Mark Paid',
        confirmKey: const Key('withdrawal_mark_paid_confirm'),
        fieldKey: const Key('withdrawal_payout_reference_field'),
        emptyError: 'Payout reference is required.',
      ),
    );
    if (reference == null) {
      return;
    }
    await onMarkPaid(reference);
  }

  Future<void> _promptReject(BuildContext context) async {
    final String? reason = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _RequiredTextDialog(
        title: 'Reject withdrawal',
        label: 'Rejection reason',
        hintText: 'Explain why this payout is being rejected',
        confirmLabel: 'Reject',
        confirmKey: const Key('withdrawal_reject_confirm'),
        fieldKey: const Key('withdrawal_reject_reason_field'),
        emptyError: 'A rejection reason is required.',
        minLength: 3,
        minLengthError: 'Reason must be at least 3 characters.',
        minLines: 2,
        maxLines: 4,
      ),
    );
    if (reason == null) {
      return;
    }
    await onReject(reason);
  }
}

/// Small dialog that requires a non-empty (optionally min-length) text value
/// before it will pop with the trimmed value.
class _RequiredTextDialog extends StatefulWidget {
  const _RequiredTextDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    required this.confirmKey,
    required this.fieldKey,
    required this.emptyError,
    this.hintText,
    this.minLength = 1,
    this.minLengthError,
    this.minLines = 1,
    this.maxLines = 1,
  });

  final String title;
  final String label;
  final String confirmLabel;
  final Key confirmKey;
  final Key fieldKey;
  final String emptyError;
  final String? hintText;
  final int minLength;
  final String? minLengthError;
  final int minLines;
  final int maxLines;

  @override
  State<_RequiredTextDialog> createState() => _RequiredTextDialogState();
}

class _RequiredTextDialogState extends State<_RequiredTextDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = widget.emptyError);
      return;
    }
    if (value.length < widget.minLength) {
      setState(() => _error = widget.minLengthError ?? widget.emptyError);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            key: widget.fieldKey,
            controller: _controller,
            autofocus: true,
            minLines: widget.minLines,
            maxLines: widget.maxLines,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hintText,
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) {
                setState(() => _error = null);
              }
            },
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: widget.confirmKey,
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
