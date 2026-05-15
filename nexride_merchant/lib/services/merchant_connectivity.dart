import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Tracks device connectivity for merchant portal UX (banner + muting writes).
class MerchantConnectivity extends ChangeNotifier {
  MerchantConnectivity() {
    _sub = Connectivity().onConnectivityChanged.listen(_onChanged);
    unawaited(_refresh());
  }

  StreamSubscription<List<ConnectivityResult>>? _sub;
  bool _online = true;

  bool get online => _online;

  Future<void> _refresh() async {
    try {
      final r = await Connectivity().checkConnectivity();
      _apply(r);
    } catch (_) {
      _online = true;
      notifyListeners();
    }
  }

  void _onChanged(List<ConnectivityResult> r) {
    _apply(r);
  }

  void _apply(List<ConnectivityResult> r) {
    final next = !r.contains(ConnectivityResult.none);
    if (next != _online) {
      _online = next;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
