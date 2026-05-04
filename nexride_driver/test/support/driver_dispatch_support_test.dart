import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/driver_dispatch_support.dart';

void main() {
  test('unexpired ride with future expiresAt stays dispatchable', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final createdAt = now - const Duration(minutes: 2).inMilliseconds;
    final expiresAt = now + const Duration(minutes: 3).inMilliseconds;

    expect(
      isRideRequestFreshForDispatch(
        createdAtMs: createdAt,
        requestedAtMs: 0,
        expiresAtMs: expiresAt,
        nowMs: now,
      ),
      isTrue,
    );
  });

  test('dispatch expiry grace keeps ride fresh shortly after expiresAt', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final createdAt = now - const Duration(minutes: 2).inMilliseconds;
    final expiresAt = now - 5000;

    expect(
      isRideRequestFreshForDispatch(
        createdAtMs: createdAt,
        requestedAtMs: 0,
        expiresAtMs: expiresAt,
        nowMs: now,
      ),
      isTrue,
    );

    expect(
      isRideRequestFreshForDispatch(
        createdAtMs: createdAt,
        requestedAtMs: 0,
        expiresAtMs: now - 25000,
        nowMs: now,
      ),
      isFalse,
    );
  });

  test('legacy ride without expiry is dispatchable within max age', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final createdAt = now - const Duration(seconds: 20).inMilliseconds;

    expect(
      isRideRequestFreshForDispatch(
        createdAtMs: createdAt,
        requestedAtMs: 0,
        expiresAtMs: 0,
        nowMs: now,
      ),
      isTrue,
    );
  });

  test('legacy ride without expiry is rejected after max age', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final createdAt = now - const Duration(minutes: 5).inMilliseconds;

    expect(
      isRideRequestFreshForDispatch(
        createdAtMs: createdAt,
        requestedAtMs: 0,
        expiresAtMs: 0,
        nowMs: now,
      ),
      isFalse,
    );
  });

  test('requested_at used when created_at missing', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final requestedAt = now - const Duration(seconds: 10).inMilliseconds;

    expect(
      isRideRequestFreshForDispatch(
        createdAtMs: 0,
        requestedAtMs: requestedAt,
        expiresAtMs: 0,
        nowMs: now,
      ),
      isTrue,
    );
  });

  test('accept started before assignment expiry stays eligible', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final assignmentExpiresAt = now + const Duration(seconds: 2).inMilliseconds;

    expect(
      wasPendingAcceptanceStartedBeforeExpiry(
        acceptRequestedAt: now,
        assignmentExpiresAt: assignmentExpiresAt,
      ),
      isTrue,
    );
  });

  test('accept started after assignment expiry is rejected', () {
    final now = DateTime(2026, 4, 14, 9).millisecondsSinceEpoch;
    final assignmentExpiresAt =
        now - const Duration(milliseconds: 1).inMilliseconds;

    expect(
      wasPendingAcceptanceStartedBeforeExpiry(
        acceptRequestedAt: now,
        assignmentExpiresAt: assignmentExpiresAt,
      ),
      isFalse,
    );
  });
}
