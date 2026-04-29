import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/realtime_database_error_support.dart';

void main() {
  group('isRealtimeDatabasePermissionDenied', () {
    test('returns true for firebase database permission-denied exceptions', () {
      final error = FirebaseException(
        plugin: 'firebase_database',
        code: 'permission-denied',
        message: 'Client does not have permission.',
      );

      expect(isRealtimeDatabasePermissionDenied(error), isTrue);
    });

    test('returns true for plugin-formatted permission-denied messages', () {
      final error = Exception(
        '[firebase_database/permission-denied] Client does not have permission to access the desired data.',
      );

      expect(isRealtimeDatabasePermissionDenied(error), isTrue);
    });

    test('returns false for unrelated database failures', () {
      final error = FirebaseException(
        plugin: 'firebase_database',
        code: 'disconnected',
        message: 'The client is offline.',
      );

      expect(isRealtimeDatabasePermissionDenied(error), isFalse);
    });
  });
}
