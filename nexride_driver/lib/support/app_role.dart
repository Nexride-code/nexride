enum AppRole {
  rider,
  driver,
}

void assertRoleScopedPath({
  required AppRole role,
  required String path,
}) {
  final normalizedPath = path.trim();
  if (role == AppRole.driver && normalizedPath.startsWith('users/')) {
    throw StateError('Driver app cannot access rider path');
  }
  if (role == AppRole.rider && normalizedPath.startsWith('drivers/')) {
    throw StateError('Rider app cannot access driver path');
  }
}
