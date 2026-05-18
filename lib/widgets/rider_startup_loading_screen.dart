import 'package:flutter/material.dart';

/// First-frame UI — avoids a blank/black screen while Firebase boots.
class RiderStartupLoadingScreen extends StatelessWidget {
  const RiderStartupLoadingScreen({
    super.key,
    this.message = 'Starting NexRide…',
  });

  final String message;

  static const Color _brandGold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4EA),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: Image.asset(
                    'assets/branding/nexride_app_icon.png',
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.local_taxi_rounded,
                      size: 80,
                      color: _brandGold,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'NexRide',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: _brandGold,
                  ),
                ),
                const SizedBox(height: 20),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: _brandGold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
