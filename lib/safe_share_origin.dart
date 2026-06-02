import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// iPad/iOS share sheet anchor that stays inside the visible viewport.
Rect safeShareOrigin(
  BuildContext context, {
  GlobalKey? buttonKey,
  Rect? override,
}) {
  final media = MediaQuery.sizeOf(context);
  final screenWidth = media.width;
  final screenHeight = media.height;

  bool isValid(Rect rect) {
    if (rect.width <= 0 || rect.height <= 0) {
      return false;
    }
    if (rect.left < 0 || rect.top < 0) {
      return false;
    }
    if (rect.right > screenWidth || rect.bottom > screenHeight) {
      return false;
    }
    return true;
  }

  if (override != null && isValid(override)) {
    debugPrint('SHARE_TRIP_ORIGIN_BUTTON_VALID source=override');
    return override;
  }

  if (buttonKey != null) {
    final buttonContext = buttonKey.currentContext;
    if (buttonContext != null) {
      final box = buttonContext.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final origin = box.localToGlobal(Offset.zero) & box.size;
        if (isValid(origin)) {
          debugPrint('SHARE_TRIP_ORIGIN_BUTTON_VALID source=button_key');
          return origin;
        }
      }
    }
  }

  debugPrint('SHARE_TRIP_ORIGIN_FALLBACK_CENTER');
  return Rect.fromCenter(
    center: Offset(screenWidth / 2, screenHeight / 2),
    width: 1,
    height: 1,
  );
}
