import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/config/rtdb_ride_request_contract.dart';

void main() {
  test('open pool lifecycle tokens stay aligned with rider requesting flow', () {
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, contains('requesting'));
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, contains('requested'));
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, contains('searching_driver'));
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, contains('matching'));
  });

  test('rules-aligned set excludes ambiguous global tokens', () {
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, isNot(contains('open')));
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, isNot(contains('idle')));
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, isNot(contains('created')));
    expect(kRtdbOpenPoolDiscoveryLifecycleTokens, isNot(contains('new')));
  });
}
