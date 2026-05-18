import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../support/production_user_messages.dart';

/// Shown when startup fails before the main app shell is ready.
class RiderStartupErrorScreen extends StatelessWidget {
  const RiderStartupErrorScreen({
    super.key,
    required this.error,
    this.stackTrace,
    this.onRetry,
    this.title = 'NexRide could not start',
  });

  final Object error;
  final StackTrace? stackTrace;
  final VoidCallback? onRetry;
  final String title;

  static const Color _brandGold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    final detail = kDebugMode ? error.toString() : null;
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4EA),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Image.asset(
                      'assets/branding/nexride_app_icon.png',
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.local_taxi_rounded,
                        size: 72,
                        color: _brandGold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    kProductionNexRideSupportMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.black54,
                      height: 1.45,
                    ),
                  ),
                  if (detail != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      detail,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black45,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(
                      backgroundColor: _brandGold,
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
