/// Shared parsing for merchant portal HTTPS callable payloads.
bool mpSuccess(dynamic value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final s = value?.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

Map<String, dynamic>? mpMerchant(dynamic raw) {
  if (raw is! Map) {
    return null;
  }
  final m = raw.map(
    (dynamic k, dynamic v) => MapEntry(k.toString(), v),
  );
  if (m.isEmpty) {
    return null;
  }
  return m;
}
