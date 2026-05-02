import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Legacy demo map — **not** used for production dispatch.
/// Live matching uses [DriverMapScreen] + Realtime Database + Cloud Functions.
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  GoogleMapController? mapController;

  bool isOnline = false;

  LatLng pickupLocation = const LatLng(6.5244, 3.3792);

  static const CameraPosition initialPosition = CameraPosition(
    target: LatLng(6.5244, 3.3792),
    zoom: 14,
  );

  void goOnline() {
    setState(() {
      isOnline = true;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Production rides use the main driver map (RTDB). '
            'Firestore ride_requests are no longer used.',
          ),
        ),
      );
    }
  }

  void goOffline() {
    setState(() {
      isOnline = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NexRide Driver (demo)'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: initialPosition,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            onMapCreated: (controller) {
              mapController = controller;
            },
          ),
          Positioned(
            bottom: 24,
            left: 16,
            right: 16,
            child: ElevatedButton(
              onPressed: isOnline ? goOffline : goOnline,
              child: Text(isOnline ? 'GO OFFLINE' : 'GO ONLINE'),
            ),
          ),
        ],
      ),
    );
  }
}
