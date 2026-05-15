import 'package:flutter_test/flutter_test.dart';
import 'package:nexride/config/rider_app_config.dart';
import 'package:nexride/services/rider_trust_rules_service.dart';
import 'package:nexride/service_type.dart';
import 'package:nexride/support/rider_fare_support.dart';

void main() {
  test('rider app enables ride, dispatch delivery, groceries, and food', () {
    final enabledServices = RiderServiceType.values
        .where((RiderServiceType service) => service.isEnabled)
        .map((RiderServiceType service) => service.key)
        .toList();

    expect(enabledServices, <String>['ride', 'dispatch_delivery', 'groceries_mart', 'restaurants_food']);
  });

  test('user verification entry hides once approval is complete', () {
    expect(RiderVerificationCopy.shouldShowEntry('approved'), isFalse);
    expect(RiderVerificationCopy.shouldShowEntry('verified'), isFalse);

    for (final status in <String>[
      'missing',
      'submitted',
      'checking',
      'pending',
      'rejected',
      'manual_review',
    ]) {
      expect(RiderVerificationCopy.shouldShowEntry(status), isTrue);
    }
  });

  test('local rider restriction toggles stay disabled for testing', () {
    expect(RiderFeatureFlags.enableRiderRestrictions, isFalse);
    expect(RiderFeatureFlags.enableCancellationFeeBlocking, isFalse);
    expect(RiderFeatureFlags.showTrustWarnings, isFalse);
    expect(RiderVerificationCopy.trustScreenTitle, 'User Verification');
  });

  test(
    'outstanding cancellation fees do not block trip requests right now',
    () {
      const service = RiderTrustRulesService();
      final decision = service.evaluateAccess(
        verification: const <String, dynamic>{'overallStatus': 'missing'},
        riskFlags: const <String, dynamic>{'status': 'clear'},
        paymentFlags: const <String, dynamic>{
          'outstandingCancellationFeesNgn': 800,
          'cashAllowed': true,
        },
        rules: const <String, dynamic>{
          'unpaidCancellationFeeBlocksTripRequests': true,
          'cashRequiresVerifiedIdentity': false,
        },
      );

      expect(decision.canRequestTrips, isTrue);
      expect(RiderFeatureFlags.disableCashTripPayments, isTrue);
      expect(decision.canUseCash, isFalse);
      expect(decision.restrictionCode, 'cash_restricted');
    },
  );

  test(
    'restricted rider risk state does not block trip requests right now',
    () {
      const service = RiderTrustRulesService();
      final decision = service.evaluateAccess(
        verification: const <String, dynamic>{'overallStatus': 'missing'},
        riskFlags: const <String, dynamic>{'status': 'restricted'},
        paymentFlags: const <String, dynamic>{
          'outstandingCancellationFeesNgn': 0,
          'cashAllowed': true,
        },
        rules: const <String, dynamic>{
          'unpaidCancellationFeeBlocksTripRequests': true,
          'cashRequiresVerifiedIdentity': false,
        },
      );

      expect(decision.canRequestTrips, isTrue);
      expect(decision.canUseCash, isFalse);
      expect(decision.restrictionCode, 'cash_restricted');
    },
  );

  test('rider alert sounds stay enabled for chat, calls, and ride updates', () {
    expect(RiderAlertSoundConfig.enableNotifications, isTrue);
    expect(RiderAlertSoundConfig.enableChatAlerts, isTrue);
    expect(RiderAlertSoundConfig.enableIncomingCallAlerts, isTrue);
    expect(RiderAlertSoundConfig.shouldPlayRideStatusAlert('accepted'), isTrue);
    expect(RiderAlertSoundConfig.shouldPlayRideStatusAlert('arrived'), isTrue);
    expect(
      RiderAlertSoundConfig.shouldPlayRideStatusAlert('searching'),
      isFalse,
    );
  });

  test(
    'Lagos fare calculation uses the official base, distance, time, and minimum rules',
    () {
      final fareBreakdown = calculateRiderFare(
        serviceKey: 'ride',
        city: 'lagos',
        distanceKm: 10,
        durationMin: 25,
        requestTime: DateTime.utc(2026, 4, 13, 13),
      );

      expect(fareBreakdown.totalFare, 2680);
      expect(fareBreakdown.bookingFeeNgn, 30);
      expect(fareBreakdown.minimumFareApplied, isFalse);
    },
  );

  test(
    'Abuja fare calculation uses the official base, distance, time, and minimum rules',
    () {
      final fareBreakdown = calculateRiderFare(
        serviceKey: 'ride',
        city: 'abuja',
        distanceKm: 10,
        durationMin: 20,
        requestTime: DateTime.utc(2026, 4, 13, 13),
      );

      expect(fareBreakdown.totalFare, 2020);
      expect(fareBreakdown.minimumFareApplied, isFalse);
    },
  );

  test('minimum fare floor applies in Lagos and Abuja for short trips', () {
    final lagosFare = calculateRiderFare(
      serviceKey: 'ride',
      city: 'lagos',
      distanceKm: 1,
      durationMin: 1,
      requestTime: DateTime.utc(2026, 4, 13, 13),
    );
    final abujaFare = calculateRiderFare(
      serviceKey: 'ride',
      city: 'abuja',
      distanceKm: 1,
      durationMin: 1,
      requestTime: DateTime.utc(2026, 4, 13, 13),
    );

    expect(lagosFare.totalFare, 1430);
    expect(lagosFare.minimumFareApplied, isTrue);
    expect(abujaFare.totalFare, 1380);
    expect(abujaFare.minimumFareApplied, isTrue);
  });

  test('launch markets cover the six supported Nigeria launch states', () {
    expect(RiderServiceAreaConfig.supportedCities, <String>[
      'lagos',
      'delta',
      'abuja',
      'anambra',
      'edo',
      'imo',
    ]);
    expect(RiderLaunchScope.normalizeSupportedCity('Yaba, Lagos'), 'lagos');
    expect(RiderLaunchScope.normalizeSupportedCity('Asaba, Delta'), 'delta');
    expect(RiderLaunchScope.normalizeSupportedCity('Wuse 2, Abuja'), 'abuja');
    expect(RiderLaunchScope.normalizeSupportedCity('Awka, Anambra'), 'anambra');
    expect(RiderLaunchScope.normalizeSupportedCity('Benin City, Edo'), 'edo');
    expect(RiderLaunchScope.normalizeSupportedCity('Owerri, Imo'), 'imo');
    expect(RiderLaunchScope.normalizeSupportedCity('Kuala Lumpur'), isNull);
  });

  test('service area fields stay canonical for Nigeria launch markets', () {
    expect(
      RiderLaunchScope.buildServiceAreaFields(city: 'lagos', area: 'Akoka'),
      <String, String>{
        'country': 'nigeria',
        'country_code': 'NG',
        'market': 'lagos',
        'area': 'yaba',
        'zone': 'yaba',
        'community': 'yaba',
      },
    );
    expect(
      RiderLaunchScope.buildServiceAreaFields(city: 'delta', area: 'Okpanam'),
      <String, String>{
        'country': 'nigeria',
        'country_code': 'NG',
        'market': 'delta',
        'area': 'asaba',
        'zone': 'asaba',
        'community': 'asaba',
      },
    );
    expect(
      RiderLaunchScope.buildServiceAreaFields(city: 'abuja', area: 'Wuse 2'),
      <String, String>{
        'country': 'nigeria',
        'country_code': 'NG',
        'market': 'abuja',
        'area': 'wuse',
        'zone': 'wuse',
        'community': 'wuse',
      },
    );
    expect(
      RiderLaunchScope.buildServiceAreaFields(city: 'anambra', area: 'Nkpor'),
      <String, String>{
        'country': 'nigeria',
        'country_code': 'NG',
        'market': 'anambra',
        'area': 'onitsha',
        'zone': 'onitsha',
        'community': 'onitsha',
      },
    );
  });

  test(
    'traffic windows apply deterministic fare multipliers in Nigeria time',
    () {
      final lagosTrafficFare = calculateRiderFare(
        serviceKey: 'ride',
        city: 'lagos',
        distanceKm: 10,
        durationMin: 25,
        requestTime: DateTime.utc(2026, 4, 13, 7, 30),
      );
      final abujaTrafficFare = calculateRiderFare(
        serviceKey: 'ride',
        city: 'abuja',
        distanceKm: 10,
        durationMin: 20,
        requestTime: DateTime.utc(2026, 4, 13, 7, 30),
      );

      expect(lagosTrafficFare.surgeMultiplier, 1.12);
      expect(lagosTrafficFare.trafficWindowLabel, 'lagos_morning_peak');
      expect(lagosTrafficFare.totalFare, 2998);
      expect(abujaTrafficFare.surgeMultiplier, 1.08);
      expect(abujaTrafficFare.trafficWindowLabel, 'abuja_morning_peak');
      expect(abujaTrafficFare.totalFare, 2179.2);
    },
  );
}
