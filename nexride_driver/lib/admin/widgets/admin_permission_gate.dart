import 'package:flutter/material.dart';

import '../admin_rbac.dart';
import '../models/admin_models.dart';

bool adminCan(AdminSession session, String permission) =>
    session.hasPermission(permission);

/// Prefer disabled UI with [kAdminNoPermissionTooltip] over hiding critical actions.
class AdminPermissionGate extends StatelessWidget {
  const AdminPermissionGate({
    super.key,
    required this.session,
    required this.permission,
    required this.child,
    this.disabledChild,
  });

  final AdminSession session;
  final String permission;
  final Widget child;
  final Widget? disabledChild;

  @override
  Widget build(BuildContext context) {
    if (session.hasPermission(permission)) {
      return child;
    }
    if (disabledChild != null) {
      return disabledChild!;
    }
    return Tooltip(
      waitDuration: const Duration(milliseconds: 350),
      message: kAdminNoPermissionTooltip,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: 0.45,
          child: AbsorbPointer(child: child),
        ),
      ),
    );
  }
}
