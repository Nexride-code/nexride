import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {

  GoogleMapController? mapController;

  bool isOnline = false;
  bool tripRequestVisible = false;
  bool tripStarted = false;
  bool tripAccepted = false;

  String? currentRideId;

  LatLng pickupLocation = const LatLng(6.5244, 3.3792);

  static const CameraPosition initialPosition = CameraPosition(
    target: LatLng(6.5244, 3.3792),
    zoom: 14,
  );

  final FirebaseFirestore firestore = FirebaseFirestore.instance;

  /// DRIVER GO ONLINE
  void goOnline() {
    setState(() {
      isOnline = true;
    });

    listenForRideRequests();
  }

  /// DRIVER GO OFFLINE
  void goOffline() {
    setState(() {
      isOnline = false;
      tripRequestVisible = false;
      tripAccepted = false;
      tripStarted = false;
    });
  }

  /// LISTEN FOR RIDER REQUESTS
  void listenForRideRequests() {

    firestore
        .collection("ride_requests")
        .where("status", isEqualTo: "searching")
        .snapshots()
        .listen((snapshot) {

      if(snapshot.docs.isNotEmpty){

        var ride = snapshot.docs.first;

        currentRideId = ride.id;

        setState(() {
          tripRequestVisible = true;
        });

      }

    });

  }

  /// DRIVER ACCEPTS RIDE
  Future<void> acceptTrip() async {

    if(currentRideId == null) return;

    try {

      String driverId = FirebaseAuth.instance.currentUser!.uid;

      await firestore
          .collection("ride_requests")
          .doc(currentRideId)
          .update({

        "status": "driver_found",
        "driver_id": driverId,
        "accepted_at": FieldValue.serverTimestamp()

      });

      setState(() {
        tripRequestVisible = false;
        tripAccepted = true;
      });

      mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(pickupLocation, 16),
      );

    } catch(e) {
      debugPrint("Accept trip error: $e");
    }

  }

  /// DRIVER DECLINES
  void declineTrip() {

    setState(() {
      tripRequestVisible = false;
    });

  }

  /// DRIVER STARTS TRIP
  Future<void> startTrip() async {

    if(currentRideId == null) return;

    try {

      await firestore
          .collection("ride_requests")
          .doc(currentRideId)
          .update({

        "status": "onTrip",
        "trip_started_at": FieldValue.serverTimestamp()

      });

      setState(() {
        tripStarted = true;
      });

    } catch(e) {
      debugPrint("Start trip error: $e");
    }

  }

  /// DRIVER ENDS TRIP
  Future<void> endTrip() async {

    if(currentRideId == null) return;

    try {

      await firestore
          .collection("ride_requests")
          .doc(currentRideId)
          .update({

        "status": "completed",
        "trip_completed_at": FieldValue.serverTimestamp()

      });

      setState(() {
        tripStarted = false;
        tripAccepted = false;
        currentRideId = null;
      });

    } catch(e) {
      debugPrint("End trip error: $e");
    }

  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(

      appBar: AppBar(
        title: const Text("NexRide Driver"),
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

          /// END TRIP BUTTON
          if(tripStarted)
          Positioned(
            bottom: 110,
            left: 20,
            right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: endTrip,
              child: const Text(
                "END TRIP",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold
                ),
              ),
            ),
          ),

          /// START TRIP BUTTON
          if(tripAccepted && !tripStarted)
          Positioned(
            bottom: 110,
            left: 20,
            right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB88A44),
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: startTrip,
              child: const Text(
                "START TRIP",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold
                ),
              ),
            ),
          ),

      

          /// ONLINE / OFFLINE BUTTON
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFB88A44),
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onPressed: () {
                if (isOnline) {
                  goOffline();
                } else {
                  goOnline();
                }
              },
              child: Text(
                isOnline ? "GO OFFLINE" : "GO ONLINE",
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

          /// TRIP REQUEST PANEL
          if (tripRequestVisible)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                height: 220,
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    const Text(
                      "New Trip Request",
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),

                    const SizedBox(height: 10),

                    const Text(
                      "Pickup: Lagos City Center",
                      style: TextStyle(color: Colors.black),
                    ),

                    const Text(
                      "Distance: 2.4 km",
                      style: TextStyle(color: Colors.black),
                    ),

                    const SizedBox(height: 20),

                    Row(
                      children: [

                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            onPressed: declineTrip,
                            child: const Text(
                              "Decline",
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),

                        const SizedBox(width: 15),

                      

                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFB88A44),
                            ),
                            onPressed: acceptTrip,
                            child: const Text(
                              "Accept",
                              style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}