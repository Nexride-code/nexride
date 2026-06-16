import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/support/delivery_offer_popup_support.dart';

void main() {
  test('detects delivery offer queue payload by request kind', () {
    expect(
      DeliveryOfferPopupSupport.isDeliveryOfferQueuePayload(<String, dynamic>{
        '__nexride_request_kind': 'delivery',
        'service_type': 'ride',
      }),
      isTrue,
    );
  });

  test('detects delivery offer queue payload by service type', () {
    expect(
      DeliveryOfferPopupSupport.isDeliveryOfferQueuePayload(<String, dynamic>{
        'service_type': 'dispatch_delivery',
      }),
      isTrue,
    );
  });

  test('accepts active offered delivery queue row', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
      DeliveryOfferPopupSupport.skipReason(
        <String, dynamic>{
          'status': 'offered',
          'delivery_state': 'searching',
          'expires_at': now + 60_000,
        },
        effectiveDriverId: 'driver_1',
        nowMs: now,
      ),
      isNull,
    );
  });

  test('rejects expired delivery offer', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
      DeliveryOfferPopupSupport.skipReason(
        <String, dynamic>{
          'status': 'offered',
          'delivery_state': 'searching',
          'expires_at': now - 1,
        },
        effectiveDriverId: 'driver_1',
        nowMs: now,
      ),
      'expired',
    );
  });

  test('rejects delivery assigned to another driver', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(
      DeliveryOfferPopupSupport.skipReason(
        <String, dynamic>{
          'status': 'accepted',
          'delivery_state': 'driver_assigned',
          'matched_driver_id': 'other_driver',
          'expires_at': now + 60_000,
        },
        effectiveDriverId: 'driver_1',
        nowMs: now,
      ),
      'assigned_to_another_driver',
    );
  });
}
