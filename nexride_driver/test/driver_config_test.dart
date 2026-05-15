import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/config/driver_app_config.dart';
import 'package:nexride_driver/support/driver_profile_support.dart';

void main() {
  test('commission model uses the centralized 10 percent rate', () {
    final businessModel = normalizedDriverBusinessModel(null);
    final commission = Map<String, dynamic>.from(
      businessModel['commission'] as Map<String, dynamic>,
    );

    expect(commission['rate'], DriverBusinessConfig.commissionRate);
    expect(
      commission['ratePercent'],
      DriverBusinessConfig.commissionRatePercent,
    );
    expect(
      formatDriverCommissionRatePercent(commission['ratePercent']),
      '10',
    );
  });

  test('subscription model exposes the official weekly and monthly prices', () {
    final businessModel = normalizedDriverBusinessModel(null);
    final subscription = Map<String, dynamic>.from(
      businessModel['subscription'] as Map<String, dynamic>,
    );

    expect(
      subscription['weeklyPriceNgn'],
      DriverBusinessConfig.weeklySubscriptionPriceNgn,
    );
    expect(
      subscription['monthlyPriceNgn'],
      DriverBusinessConfig.monthlySubscriptionPriceNgn,
    );
    expect(
      subscription['priceLabel'],
      'Weekly ₦7,000 • Monthly ₦25,000',
    );
  });

  test('pricing snapshot overrides commission and subscription amounts', () {
    final businessModel = normalizedDriverBusinessModel(
      const <String, dynamic>{
        'selectedModel': 'subscription',
        'pricingSnapshot': <String, dynamic>{
          'commissionRate': 0.18,
          'weeklySubscriptionNgn': 11000,
          'monthlySubscriptionNgn': 38000,
        },
        'subscription': <String, dynamic>{
          'status': 'active',
          'planType': 'weekly',
          'renewalDate': '2099-12-31T00:00:00Z',
        },
      },
    );
    final commission = Map<String, dynamic>.from(
      businessModel['commission'] as Map<String, dynamic>,
    );
    final subscription = Map<String, dynamic>.from(
      businessModel['subscription'] as Map<String, dynamic>,
    );

    expect(commission['rate'], 0.18);
    expect(commission['ratePercent'], 18.0);
    expect(subscription['weeklyPriceNgn'], 11000);
    expect(subscription['monthlyPriceNgn'], 38000);
    expect(
      subscription['priceLabel'],
      'Weekly ₦11,000 • Monthly ₦38,000',
    );
  });

  test('commission payout deducts exactly 10 percent per completed trip', () {
    final settlement = calculateDriverTripSettlement(
      grossFare: 2650,
      businessModel: normalizedDriverBusinessModel(null),
    );

    expect(settlement.appliedModel, 'commission');
    expect(settlement.commissionRate, 0.10);
    expect(settlement.commissionAmount, 265);
    expect(settlement.netPayout, 2385);
  });

  test('commission payout follows the backend-configured commission rate', () {
    final settlement = calculateDriverTripSettlement(
      grossFare: 5000,
      businessModel: normalizedDriverBusinessModel(
        const <String, dynamic>{
          'pricingSnapshot': <String, dynamic>{'commissionRate': 0.15},
        },
      ),
    );

    expect(settlement.appliedModel, 'commission');
    expect(settlement.commissionRate, 0.15);
    expect(settlement.commissionAmount, 750);
    expect(settlement.netPayout, 4250);
  });

  test('active subscription payout keeps 100 percent of trip earnings', () {
    final settlement = calculateDriverTripSettlement(
      grossFare: 1990,
      businessModel: normalizedDriverBusinessModel(
        const <String, dynamic>{
          'selectedModel': 'subscription',
          'subscription': <String, dynamic>{
            'status': 'active',
            'renewalDate': '2099-12-31T00:00:00Z',
          },
        },
      ),
    );

    expect(settlement.appliedModel, 'subscription');
    expect(settlement.subscriptionActive, isTrue);
    expect(settlement.commissionAmount, 0);
    expect(settlement.netPayout, 1990);
  });

  test('inactive or expired subscriptions fall back to commission payouts', () {
    final inactiveSettlement = calculateDriverTripSettlement(
      grossFare: 1990,
      businessModel: normalizedDriverBusinessModel(
        const <String, dynamic>{
          'selectedModel': 'subscription',
          'subscription': <String, dynamic>{'status': 'inactive'},
        },
      ),
    );
    final expiredSettlement = calculateDriverTripSettlement(
      grossFare: 1990,
      businessModel: normalizedDriverBusinessModel(
        const <String, dynamic>{
          'selectedModel': 'subscription',
          'subscription': <String, dynamic>{
            'status': 'active',
            'renewalDate': '2020-01-01T00:00:00Z',
          },
        },
      ),
    );

    expect(inactiveSettlement.appliedModel, 'commission');
    expect(inactiveSettlement.commissionAmount, 199);
    expect(inactiveSettlement.netPayout, 1791);
    expect(expiredSettlement.appliedModel, 'commission');
    expect(expiredSettlement.subscriptionStatus, 'expired');
    expect(expiredSettlement.commissionAmount, 199);
    expect(expiredSettlement.netPayout, 1791);
  });

  test(
    'saved settlement records keep subscription trips commission free',
    () {
      final settlementRecord = buildDriverTripSettlementRecord(
        grossFare: 1990,
        businessModel: normalizedDriverBusinessModel(
          const <String, dynamic>{
            'selectedModel': 'subscription',
            'subscription': <String, dynamic>{
              'status': 'active',
              'renewalDate': '2099-12-31T00:00:00Z',
            },
          },
        ),
        paymentMethod: 'flutterwave',
        settlementStatus: 'trip_completed',
        completionState: 'driver_marked_completed',
        city: 'abuja',
      );

      expect(settlementRecord['appliedModel'], 'subscription');
      expect(settlementRecord['commissionAmountNgn'], 0);
      expect(settlementRecord['driverPayoutNgn'], 1990);
      expect(settlementRecord['countsTowardWallet'], isTrue);
    },
  );

  test(
    'saved settlement records fall back to 10 percent when a subscription is expired',
    () {
      final settlementRecord = buildDriverTripSettlementRecord(
        grossFare: 1990,
        businessModel: normalizedDriverBusinessModel(
          const <String, dynamic>{
            'selectedModel': 'subscription',
            'subscription': <String, dynamic>{
              'status': 'active',
              'renewalDate': '2020-01-01T00:00:00Z',
            },
          },
        ),
        paymentMethod: 'flutterwave',
        settlementStatus: 'trip_completed',
        completionState: 'driver_marked_completed',
        city: 'abuja',
      );

      expect(settlementRecord['appliedModel'], 'commission');
      expect(settlementRecord['commissionAmountNgn'], 199);
      expect(settlementRecord['driverPayoutNgn'], 1791);
      expect(settlementRecord['countsTowardWallet'], isTrue);
    },
  );

  test('monetization labels distinguish weekly and monthly subscriptions', () {
    final weeklySubscription = normalizedDriverBusinessModel(
      const <String, dynamic>{
        'selectedModel': 'subscription',
        'subscription': <String, dynamic>{
          'status': 'active',
          'planType': 'weekly',
          'renewalDate': '2099-12-31T00:00:00Z',
        },
      },
    );
    final monthlySubscription = normalizedDriverBusinessModel(
      const <String, dynamic>{
        'selectedModel': 'subscription',
        'subscription': <String, dynamic>{
          'status': 'active',
          'planType': 'monthly',
          'renewalDate': '2099-12-31T00:00:00Z',
        },
      },
    );

    expect(driverSelectedMonetizationModeLabel(weeklySubscription),
        'Weekly subscription');
    expect(
      driverAppliedMonetizationModeLabel(monthlySubscription),
      'Monthly subscription',
    );
  });

  test('driver profile builder normalizes uid, path, and service defaults', () {
    final profile = buildDriverProfileRecord(
      driverId: 'driver_123',
      existing: const <String, dynamic>{'name': 'Ada'},
      fallbackEmail: 'ada@example.com',
    );

    expect(driverProfilePath('driver_123'), 'drivers/driver_123');
    expect(profile['id'], 'driver_123');
    expect(profile['uid'], 'driver_123');
    expect(profile['name'], 'Ada');
    expect(profile['serviceTypes'], kDriverServiceTypes);
    expect(
      Map<String, dynamic>.from(profile['verification'] as Map)['status'],
      isNotEmpty,
    );
  });

  test('driver verification bypass keeps active services requestable', () {
    final verification = normalizedDriverVerification(null);

    expect(DriverFeatureFlags.driverVerificationRequired, isFalse);
    expect(driverVerificationCanGoOnline(verification), isTrue);
    expect(driverServiceCanReceiveRequests(verification, 'ride'), isTrue);
    expect(
      driverServiceCanReceiveRequests(verification, 'dispatch_delivery'),
      isTrue,
    );
    expect(
      driverServiceCanReceiveRequests(verification, 'groceries_mart'),
      isTrue,
    );
    expect(
      driverServiceCanReceiveRequests(verification, 'restaurants_food'),
      isTrue,
    );
  });

  test('driver alert sounds stay enabled for requests, chat, and calls', () {
    expect(DriverAlertSoundConfig.enableRideRequestAlerts, isTrue);
    expect(DriverAlertSoundConfig.enableChatAlerts, isTrue);
    expect(DriverAlertSoundConfig.enableIncomingCallAlerts, isTrue);
    expect(DriverAlertSoundConfig.alertAssetPath, 'assets/sounds/ride_request.mp3');
  });

  test('driver launch markets cover the five supported Nigeria states', () {
    expect(
      DriverServiceAreaConfig.supportedCities,
      <String>['lagos', 'delta', 'abuja', 'anambra', 'edo'],
    );
    expect(DriverLaunchScope.normalizeSupportedCity('Ikeja, Lagos'), 'lagos');
    expect(DriverLaunchScope.normalizeSupportedCity('Asaba, Delta'), 'delta');
    expect(DriverLaunchScope.normalizeSupportedCity('Maitama, Abuja'), 'abuja');
    expect(
        DriverLaunchScope.normalizeSupportedCity('Awka, Anambra'), 'anambra');
    expect(
      DriverLaunchScope.normalizeSupportedCity('Benin City, Edo'),
      'edo',
    );
    expect(DriverLaunchScope.normalizeSupportedCity('Penang'), isNull);
  });

  test('driver service area fields normalize local launch areas', () {
    expect(
      DriverLaunchScope.buildServiceAreaFields(city: 'lagos', area: 'Akoka'),
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
      DriverLaunchScope.buildServiceAreaFields(city: 'delta', area: 'Okpanam'),
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
      DriverLaunchScope.buildServiceAreaFields(city: 'abuja', area: 'Wuse 2'),
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
      DriverLaunchScope.buildServiceAreaFields(city: 'anambra', area: 'Nkpor'),
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

  test('driver dispatch radius stays scoped to nearby requests', () {
    expect(DriverDispatchConfig.nearbyRequestRadiusMeters, 30000);
  });
}
