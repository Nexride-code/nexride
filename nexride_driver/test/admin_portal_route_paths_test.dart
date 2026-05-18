import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/admin/admin_config.dart';

void main() {
  test('/system-health resolves to AdminSection.systemHealth', () {
    expect(
      AdminPortalRoutePaths.sectionForPath('/system-health'),
      AdminSection.systemHealth,
    );
    expect(
      AdminPortalRoutePaths.sectionForPath('/admin/system-health'),
      AdminSection.systemHealth,
    );
  });

  test('pathForSection systemHealth round-trips', () {
    expect(
      AdminPortalRoutePaths.pathForSection(AdminSection.systemHealth),
      AdminPortalRoutePaths.systemHealth,
    );
  });

  test('/system-health is a protected route', () {
    expect(
      AdminPortalRoutePaths.isProtectedRoute('/system-health'),
      isTrue,
    );
  });
}
