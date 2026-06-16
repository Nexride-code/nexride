import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/services/call_remote_peer_watchdog.dart';

void main() {
  group('RemotePeerWatchdogPolicy', () {
    const policy = RemotePeerWatchdogPolicy(
      warnInterval: Duration(seconds: 13),
      maxWaitWithoutRemote: Duration(seconds: 50),
      maxWarnCountBeforeFail: 2,
    );

    test('first timeout warns without failing while RTDB session stays active', () {
      final tick = policy.evaluateTick(
        fireCount: 1,
        elapsedSinceLocalJoin: const Duration(seconds: 13),
      );

      expect(tick.shouldWarn, isTrue);
      expect(tick.shouldFail, isFalse);
      expect(
        tick.statusMessage,
        RemotePeerWatchdogPolicy.waitingForRemoteMessage,
      );
    });

    test('second timeout fails stuck local-only call', () {
      final tick = policy.evaluateTick(
        fireCount: 2,
        elapsedSinceLocalJoin: const Duration(seconds: 26),
      );

      expect(tick.shouldWarn, isTrue);
      expect(tick.shouldFail, isTrue);
    });

    test('elapsed max wait fails even on first fire count', () {
      final tick = policy.evaluateTick(
        fireCount: 1,
        elapsedSinceLocalJoin: const Duration(seconds: 50),
      );

      expect(tick.shouldFail, isTrue);
    });

    test('remote join before timeout would not evaluate as failure at fire zero', () {
      final tick = policy.evaluateTick(
        fireCount: 0,
        elapsedSinceLocalJoin: Duration.zero,
      );

      expect(tick.shouldWarn, isFalse);
      expect(tick.shouldFail, isFalse);
    });
  });
}
