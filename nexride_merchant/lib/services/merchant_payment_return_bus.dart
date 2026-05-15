import 'dart:async';

/// In-app bus for Flutterwave return deep links (wallet screen listens).
class MerchantPaymentReturnBus {
  MerchantPaymentReturnBus._();
  static final MerchantPaymentReturnBus instance = MerchantPaymentReturnBus._();

  final StreamController<MerchantPaymentReturnEvent> _controller =
      StreamController<MerchantPaymentReturnEvent>.broadcast();

  Stream<MerchantPaymentReturnEvent> get stream => _controller.stream;

  void publish(MerchantPaymentReturnEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }
}

class MerchantPaymentReturnEvent {
  const MerchantPaymentReturnEvent({
    required this.txRef,
    this.transactionId,
    this.status,
    this.flow,
    this.merchantId,
  });

  final String txRef;
  final String? transactionId;
  final String? status;
  final String? flow;
  final String? merchantId;

  bool get isCancelled {
    final s = (status ?? '').trim().toLowerCase();
    return s == 'cancelled' || s == 'canceled' || s == 'cancel';
  }
}
