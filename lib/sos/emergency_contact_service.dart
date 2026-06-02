import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/foundation.dart';

class EmergencyContact {
  const EmergencyContact({
    required this.name,
    required this.phone,
    required this.relationship,
    this.updatedAt,
  });

  final String name;
  final String phone;
  final String relationship;
  final int? updatedAt;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'name': name,
        'phone': phone,
        'relationship': relationship,
        'updatedAt': updatedAt ?? DateTime.now().millisecondsSinceEpoch,
      };

  static EmergencyContact? fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) {
      return null;
    }
    final name = raw['name']?.toString().trim() ?? '';
    final phone = raw['phone']?.toString().trim() ?? '';
    if (name.isEmpty || phone.isEmpty) {
      return null;
    }
    return EmergencyContact(
      name: name,
      phone: phone,
      relationship: raw['relationship']?.toString().trim() ?? '',
      updatedAt: int.tryParse('${raw['updatedAt'] ?? raw['updated_at'] ?? ''}'),
    );
  }
}

class EmergencyContactService {
  EmergencyContactService({rtdb.FirebaseDatabase? database})
      : _database = database ?? rtdb.FirebaseDatabase.instance;

  final rtdb.FirebaseDatabase _database;

  rtdb.DatabaseReference _ref(String uid) =>
      _database.ref('users/$uid/emergency_contact');

  Future<EmergencyContact?> load(String uid) async {
    final snap = await _ref(uid).get();
    if (!snap.exists || snap.value is! Map) {
      return null;
    }
    return EmergencyContact.fromMap(
      Map<dynamic, dynamic>.from(snap.value! as Map),
    );
  }

  Future<void> save(String uid, EmergencyContact contact) async {
    await _ref(uid).set(contact.toMap());
    debugPrint('SOS_EMERGENCY_CONTACT_ADD_OK uid=$uid');
  }
}

String sanitizePhoneForDial(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (digits.isEmpty) {
    return '';
  }
  if (digits.startsWith('+')) {
    return digits;
  }
  if (digits.startsWith('0') && digits.length >= 10) {
    return '+234${digits.substring(1)}';
  }
  if (digits.length == 10 || digits.length == 11) {
    final normalized = digits.startsWith('0') ? digits.substring(1) : digits;
    return '+234$normalized';
  }
  return digits;
}
