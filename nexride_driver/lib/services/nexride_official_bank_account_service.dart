import 'package:nexride_driver/services/ride_cloud_functions_service.dart';

/// NexRide corporate bank account for manual transfers — from callable
/// `getNexrideOfficialBankAccount` (RTDB `app_config/nexride_official_bank_account`).
class NexrideOfficialBankAccount {
  const NexrideOfficialBankAccount({
    required this.bankName,
    required this.accountName,
    required this.accountNumber,
  });

  final String bankName;
  final String accountName;
  final String accountNumber;
}

class NexrideOfficialBankAccountService {
  NexrideOfficialBankAccountService._(this._cloud);
  static final NexrideOfficialBankAccountService instance =
      NexrideOfficialBankAccountService._(RideCloudFunctionsService());

  final RideCloudFunctionsService _cloud;
  NexrideOfficialBankAccount? _cached;

  Future<NexrideOfficialBankAccount?> fetch({bool forceRefresh = false}) async {
    if (_cached != null && !forceRefresh) {
      return _cached;
    }
    final m = await _cloud.getNexrideOfficialBankAccount();
    if (m['success'] != true) {
      return null;
    }
    final bankName = '${m['bank_name'] ?? ''}'.trim();
    final accountName = '${m['account_name'] ?? ''}'.trim();
    final accountNumber = '${m['account_number'] ?? ''}'.trim();
    if (bankName.isEmpty || accountName.isEmpty || accountNumber.isEmpty) {
      return null;
    }
    _cached = NexrideOfficialBankAccount(
      bankName: bankName,
      accountName: accountName,
      accountNumber: accountNumber,
    );
    return _cached;
  }

  void clearCache() {
    _cached = null;
  }
}
