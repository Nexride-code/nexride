import 'package:flutter/foundation.dart';

class PaymentGatewayConfig {
  static const flutterwavePublicKey = String.fromEnvironment(
    'FLUTTERWAVE_PUBLIC_KEY',
  );
  static const flutterwaveSecretKey = String.fromEnvironment(
    'FLUTTERWAVE_SECRET_KEY',
  );
  static const flutterwaveWebhookSecret = String.fromEnvironment(
    'FLUTTERWAVE_WEBHOOK_SECRET',
  );
}

enum PaymentTransactionStatus { pending, successful, failed }

class PaymentInitializationResult {
  const PaymentInitializationResult({
    required this.reference,
    required this.authorizationUrl,
  });

  final String reference;
  final String authorizationUrl;
}

class PaymentVerificationResult {
  const PaymentVerificationResult({
    required this.reference,
    required this.status,
    required this.amount,
    required this.providerPayload,
  });

  final String reference;
  final PaymentTransactionStatus status;
  final double amount;
  final Map<String, dynamic> providerPayload;
}

abstract class PaymentGatewayService {
  Future<PaymentInitializationResult> initializePayment({
    required String idempotencyKey,
    required String customerId,
    required String bookingId,
    required double amount,
    required String currency,
    required String description,
  });

  Future<PaymentVerificationResult> verifyPayment({
    required String transactionReference,
  });

  Future<void> handleWebhook({
    required String signature,
    required Map<String, dynamic> payload,
  });

  Future<void> recordTransaction({
    required PaymentVerificationResult verification,
    required String bookingId,
    required String customerId,
  });

  Future<void> markPaymentSuccessful({
    required String bookingId,
    required String reference,
  });

  Future<void> markPaymentFailed({
    required String bookingId,
    required String reference,
    required String reason,
  });
}

class NoopPaymentGatewayService implements PaymentGatewayService {
  const NoopPaymentGatewayService();

  @override
  Future<PaymentInitializationResult> initializePayment({
    required String idempotencyKey,
    required String customerId,
    required String bookingId,
    required double amount,
    required String currency,
    required String description,
  }) async {
    debugPrint(
      '[PaymentGateway] initializePayment noop bookingId=$bookingId reference=$idempotencyKey',
    );
    return PaymentInitializationResult(
      reference: idempotencyKey,
      authorizationUrl: '',
    );
  }

  @override
  Future<PaymentVerificationResult> verifyPayment({
    required String transactionReference,
  }) async {
    debugPrint(
      '[PaymentGateway] verifyPayment noop reference=$transactionReference',
    );
    return PaymentVerificationResult(
      reference: transactionReference,
      status: PaymentTransactionStatus.pending,
      amount: 0,
      providerPayload: const <String, dynamic>{},
    );
  }

  @override
  Future<void> handleWebhook({
    required String signature,
    required Map<String, dynamic> payload,
  }) async {
    debugPrint('[PaymentGateway] handleWebhook noop');
  }

  @override
  Future<void> markPaymentFailed({
    required String bookingId,
    required String reference,
    required String reason,
  }) async {
    debugPrint(
      '[PaymentGateway] markPaymentFailed noop bookingId=$bookingId reference=$reference reason=$reason',
    );
  }

  @override
  Future<void> markPaymentSuccessful({
    required String bookingId,
    required String reference,
  }) async {
    debugPrint(
      '[PaymentGateway] markPaymentSuccessful noop bookingId=$bookingId reference=$reference',
    );
  }

  @override
  Future<void> recordTransaction({
    required PaymentVerificationResult verification,
    required String bookingId,
    required String customerId,
  }) async {
    debugPrint(
      '[PaymentGateway] recordTransaction noop bookingId=$bookingId reference=${verification.reference}',
    );
  }
}
