import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Old hosted links used `/ride?rideId=&token=`. Forward to canonical `/trip/:rideId`.
class RideLegacyRedirectPage extends StatefulWidget {
  const RideLegacyRedirectPage({
    super.key,
    required this.rideId,
    required this.token,
  });

  final String rideId;
  final String token;

  @override
  State<RideLegacyRedirectPage> createState() => _RideLegacyRedirectPageState();
}

class _RideLegacyRedirectPageState extends State<RideLegacyRedirectPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _go());
  }

  void _go() {
    if (!mounted) return;
    final id = widget.rideId.trim();
    final t = widget.token.trim();
    if (id.isEmpty || t.isEmpty) {
      context.go('/');
      return;
    }
    context.go(
      Uri(
        path: '/trip/${Uri.encodeComponent(id)}',
        queryParameters: <String, String>{'token': t},
      ).toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Opening trip…'),
          ],
        ),
      ),
    );
  }
}
