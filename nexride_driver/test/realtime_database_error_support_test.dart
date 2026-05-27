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

  group('sanitizeDriverProfileRtdbUpdate', () {
    test('strips server-authoritative market fields from profile writes', () {
      final sanitized = sanitizeDriverProfileRtdbUpdate(<String, Object?>{
        'lat': 6.5,
        'market': 'lagos',
        'city': 'lagos',
        'launch_market_city': 'lagos',
        'service_area': <String, Object?>{
          'country': 'nigeria',
          'market': 'lagos',
          'canonical_market_id': 'lagos',
          'area': 'yaba',
        },
      });

      expect(sanitized.containsKey('market'), isFalse);
      expect(sanitized.containsKey('city'), isFalse);
      expect(sanitized['launch_market_city'], 'lagos');
      final serviceArea = sanitized['service_area'] as Map<String, Object?>;
      expect(serviceArea.containsKey('market'), isFalse);
      expect(serviceArea.containsKey('canonical_market_id'), isFalse);
      expect(serviceArea['area'], 'yaba');
    });
  });
}
