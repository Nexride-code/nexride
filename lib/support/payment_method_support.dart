enum PaymentMethodType { card, bank }

extension PaymentMethodTypeX on PaymentMethodType {
  String get key => switch (this) {
    PaymentMethodType.card => 'card',
    PaymentMethodType.bank => 'bank',
  };

  String get label => switch (this) {
    PaymentMethodType.card => 'Link Card',
    PaymentMethodType.bank => 'Link Bank Account',
  };

  String get noun => switch (this) {
    PaymentMethodType.card => 'card',
    PaymentMethodType.bank => 'bank account',
  };
}

PaymentMethodType paymentMethodTypeFromKey(String rawValue) {
  switch (rawValue.trim().toLowerCase()) {
    case 'bank':
    case 'bank_account':
    case 'bank account':
      return PaymentMethodType.bank;
    default:
      return PaymentMethodType.card;
  }
}

String paymentMethodsPath(String riderId) => 'payment_methods/$riderId';
String userPaymentMethodsPath(String riderId) => 'users/$riderId/payment_methods';

class PaymentMethodRecord {
  const PaymentMethodRecord({
    required this.id,
    required this.riderId,
    required this.type,
    required this.provider,
    required this.maskedDetails,
    required this.status,
    required this.isDefault,
    required this.createdAt,
    required this.updatedAt,
    required this.displayTitle,
    required this.detailLabel,
    required this.tokenRef,
    required this.providerReference,
    required this.country,
    required this.last4,
  });

  final String id;
  final String riderId;
  final PaymentMethodType type;
  final String provider;
  final String maskedDetails;
  final String status;
  final bool isDefault;
  final int createdAt;
  final int updatedAt;
  final String displayTitle;
  final String detailLabel;
  final String tokenRef;
  final String providerReference;
  final String country;
  final String last4;

  factory PaymentMethodRecord.fromMap(
    String riderId,
    String methodId,
    Map<String, dynamic> value,
  ) {
    final type = paymentMethodTypeFromKey(value['type']?.toString() ?? 'card');
    final provider = value['provider']?.toString().trim() ?? '';
    final tokenRef = value['token_ref']?.toString().trim() ??
        value['tokenRef']?.toString().trim() ??
        '';
    final providerReference = value['provider_reference']?.toString().trim() ??
        value['providerReference']?.toString().trim() ??
        '';
    final last4 =
        value['last4']?.toString().trim() ?? _extractLast4(value['maskedDetails']);
    final maskedDetails =
        value['maskedDetails']?.toString().trim().isNotEmpty == true
            ? value['maskedDetails'].toString().trim()
            : (last4.isEmpty
                  ? ''
                  : (type == PaymentMethodType.card
                        ? '**** **** **** $last4'
                        : '****$last4'));
    final title = value['displayTitle']?.toString().trim().isNotEmpty == true
        ? value['displayTitle'].toString().trim()
        : (type == PaymentMethodType.card ? 'Linked card' : 'Linked bank');
    final detailLabel =
        value['detailLabel']?.toString().trim().isNotEmpty == true
        ? value['detailLabel'].toString().trim()
        : maskedDetails;

    return PaymentMethodRecord(
      id: methodId,
      riderId: riderId,
      type: type,
      provider: provider,
      maskedDetails: maskedDetails,
      status: value['status']?.toString().trim().isNotEmpty == true
          ? value['status'].toString().trim()
          : 'linked',
      isDefault: value['isDefault'] == true || value['is_default'] == true,
      createdAt: _intValue(value['createdAt'] ?? value['created_at']),
      updatedAt: _intValue(value['updatedAt'] ?? value['updated_at']),
      displayTitle: title,
      detailLabel: detailLabel,
      tokenRef: tokenRef,
      providerReference: providerReference,
      country: value['country']?.toString().trim().isNotEmpty == true
          ? value['country'].toString().trim()
          : 'NG',
      last4: last4,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'riderId': riderId,
      'type': type.key,
      'provider': provider,
      'maskedDetails': maskedDetails,
      'status': status,
      'isDefault': isDefault,
      'displayTitle': displayTitle,
      'detailLabel': detailLabel,
      'token_ref': tokenRef,
      'provider_reference': providerReference,
      'country': country,
      'last4': last4,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}

class PaymentMethodDraft {
  const PaymentMethodDraft({
    required this.riderId,
    required this.type,
    required this.provider,
    required this.maskedDetails,
    required this.displayTitle,
    required this.detailLabel,
    required this.tokenRef,
    required this.providerReference,
    required this.country,
    required this.last4,
    this.makeDefault = false,
  });

  final String riderId;
  final PaymentMethodType type;
  final String provider;
  final String maskedDetails;
  final String displayTitle;
  final String detailLabel;
  final String tokenRef;
  final String providerReference;
  final String country;
  final String last4;
  final bool makeDefault;
}

String _extractLast4(dynamic masked) {
  final raw = masked?.toString() ?? '';
  final digitsOnly = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digitsOnly.length < 4) {
    return '';
  }
  return digitsOnly.substring(digitsOnly.length - 4);
}

int _intValue(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
