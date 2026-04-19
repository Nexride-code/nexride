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

  factory PaymentMethodRecord.fromMap(
    String riderId,
    String methodId,
    Map<String, dynamic> value,
  ) {
    final type = paymentMethodTypeFromKey(value['type']?.toString() ?? 'card');
    final provider = value['provider']?.toString().trim() ?? '';
    final maskedDetails = value['maskedDetails']?.toString().trim() ?? '';
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
      isDefault: value['isDefault'] == true,
      createdAt: _intValue(value['createdAt']),
      updatedAt: _intValue(value['updatedAt']),
      displayTitle: title,
      detailLabel: detailLabel,
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
    this.makeDefault = false,
  });

  final String riderId;
  final PaymentMethodType type;
  final String provider;
  final String maskedDetails;
  final String displayTitle;
  final String detailLabel;
  final bool makeDefault;
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
