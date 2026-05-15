import 'admin_config.dart';

/// Tooltip for disabled admin actions (matches product copy request).
const String kAdminNoPermissionTooltip =
    'You do not have permission for this action.';

const Set<String> kNexrideAdminRoles = <String>{
  'super_admin',
  'ops_admin',
  'finance_admin',
  'support_admin',
  'verification_admin',
  'merchant_ops_admin',
};

/// Mirrors backend `ROLE_PERMISSIONS` in `admin_permissions.js` — keep in sync on changes.
Set<String> permissionsForAdminRole(String role) {
  final String r = role.trim().toLowerCase();
  const Set<String> all = <String>{
    'dashboard.read',
    'riders.read',
    'riders.write',
    'drivers.read',
    'drivers.write',
    'trips.read',
    'trips.write',
    'finance.read',
    'finance.write',
    'withdrawals.read',
    'withdrawals.approve',
    'verification.read',
    'verification.approve',
    'support.read',
    'support.write',
    'merchants.read',
    'merchants.write',
    'service_areas.read',
    'service_areas.write',
    'audit_logs.read',
    'settings.read',
    'settings.write',
  };

  switch (r) {
    case 'super_admin':
      return all;
    case 'ops_admin':
      return <String>{
        'dashboard.read',
        'riders.read',
        'riders.write',
        'drivers.read',
        'drivers.write',
        'trips.read',
        'trips.write',
        'finance.read',
        'support.read',
        'support.write',
        'merchants.read',
        'merchants.write',
        'service_areas.read',
        'service_areas.write',
        'settings.read',
      };
    case 'finance_admin':
      return <String>{
        'dashboard.read',
        'riders.read',
        'drivers.read',
        'finance.read',
        'finance.write',
        'withdrawals.read',
        'withdrawals.approve',
      };
    case 'support_admin':
      return <String>{
        'dashboard.read',
        'riders.read',
        'riders.write',
        'drivers.read',
        'trips.read',
        'support.read',
        'support.write',
      };
    case 'verification_admin':
      return <String>{
        'dashboard.read',
        'drivers.read',
        'drivers.write',
        'verification.read',
        'verification.approve',
        'riders.read',
      };
    case 'merchant_ops_admin':
      return <String>{
        'dashboard.read',
        'merchants.read',
        'merchants.write',
        'service_areas.read',
        'service_areas.write',
      };
    default:
      return <String>{};
  }
}

String? requiredPermissionForSection(AdminSection section) {
  return switch (section) {
    AdminSection.dashboard => 'dashboard.read',
    AdminSection.riders => 'riders.read',
    AdminSection.drivers => 'drivers.read',
    AdminSection.trips => 'trips.read',
    AdminSection.liveOperations => 'trips.read',
    AdminSection.systemHealth => 'dashboard.read',
    AdminSection.finance => 'finance.read',
    AdminSection.withdrawals => 'withdrawals.read',
    AdminSection.pricing => 'settings.read',
    AdminSection.subscriptions => 'drivers.read',
    AdminSection.verification => 'verification.read',
    AdminSection.support => 'support.read',
    AdminSection.regions => 'service_areas.read',
    AdminSection.serviceAreas => 'service_areas.read',
    AdminSection.merchants => 'merchants.read',
    AdminSection.settings => 'settings.read',
    AdminSection.auditLogs => 'audit_logs.read',
  };
}

String formatAdminRoleLabel(String role) {
  final String r = role.trim().toLowerCase();
  if (r.isEmpty) {
    return 'Admin';
  }
  return r
      .split('_')
      .map((String p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}')
      .join(' ');
}
