/// Pure timing policy for remote Agora peer presence after local join succeeds.
class RemotePeerWatchdogPolicy {
  const RemotePeerWatchdogPolicy({
    this.warnInterval = const Duration(seconds: 13),
    this.maxWaitWithoutRemote = const Duration(seconds: 40),
    this.maxWarnCountBeforeFail = 2,
  });

  final Duration warnInterval;
  final Duration maxWaitWithoutRemote;
  final int maxWarnCountBeforeFail;

  static const String waitingForRemoteMessage =
      'Waiting for the other party to connect…';
  static const String connectingToRemoteMessage =
      'Connecting to other party…';

  RemotePeerWatchdogTick evaluateTick({
    required int fireCount,
    required Duration elapsedSinceLocalJoin,
  }) {
    if (fireCount <= 0) {
      return const RemotePeerWatchdogTick(shouldWarn: false, shouldFail: false);
    }

    final shouldFail = fireCount >= maxWarnCountBeforeFail ||
        elapsedSinceLocalJoin >= maxWaitWithoutRemote;
    if (shouldFail) {
      return const RemotePeerWatchdogTick(
        shouldWarn: true,
        shouldFail: true,
        statusMessage: waitingForRemoteMessage,
      );
    }

    return RemotePeerWatchdogTick(
      shouldWarn: true,
      shouldFail: false,
      statusMessage:
          fireCount == 1 ? waitingForRemoteMessage : connectingToRemoteMessage,
    );
  }
}

class RemotePeerWatchdogTick {
  const RemotePeerWatchdogTick({
    required this.shouldWarn,
    required this.shouldFail,
    this.statusMessage,
  });

  final bool shouldWarn;
  final bool shouldFail;
  final String? statusMessage;
}
