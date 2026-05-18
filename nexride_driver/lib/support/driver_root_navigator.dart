import 'package:flutter/material.dart';

/// Root navigator for driver UI overlays (offer popup must render above map).
final GlobalKey<NavigatorState> driverRootNavigatorKey =
    GlobalKey<NavigatorState>();

BuildContext? get driverRootNavigatorContext =>
    driverRootNavigatorKey.currentContext;
