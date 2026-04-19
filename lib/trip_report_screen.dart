import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';

import 'services/trip_safety_service.dart';
import 'service_type.dart';

class TripReportScreen extends StatefulWidget {
  const TripReportScreen({
    super.key,
    required this.tripId,
    required this.riderId,
    required this.tripData,
  });

  final String tripId;
  final String riderId;
  final Map<String, dynamic> tripData;

  @override
  State<TripReportScreen> createState() => _TripReportScreenState();
}

class _TripReportScreenState extends State<TripReportScreen> {
  static const Color _gold = Color(0xFFB57A2A);
  static const List<String> _reasonOptions = <String>[
    'driver behavior',
    'fare issue',
    'lost item',
    'safety concern',
    'wrong pickup/dropoff',
    'other',
  ];

  final TextEditingController _messageController = TextEditingController();
  final TripSafetyTelemetryService _tripSafetyService =
      TripSafetyTelemetryService();
  bool _submitting = false;
  String _selectedReason = _reasonOptions.first;

  RiderServiceType get _serviceType => riderServiceTypeFromKey(
    (widget.tripData['service_type'] ?? widget.tripData['serviceType'])
        ?.toString(),
  );

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submitReport() async {
    if (_submitting) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
    });

    debugPrint(
      '[TripReport] submit tapped tripId=${widget.tripId} reason=$_selectedReason',
    );

    try {
      final reportsRef = rtdb.FirebaseDatabase.instance.ref(
        'support_reports/trips',
      );
      final reportRef = reportsRef.push();

      final payload = <String, dynamic>{
        'reportId': reportRef.key,
        'tripId': widget.tripId,
        'riderId': widget.riderId,
        'driverId': widget.tripData['driver_id']?.toString() ?? '',
        'serviceType': _serviceType.key,
        'reason': _selectedReason,
        'message': _messageController.text.trim(),
        'status': 'pending',
        'createdAt': rtdb.ServerValue.timestamp,
      };

      debugPrint('[TripReport] payload=$payload');
      await reportRef.set(payload);
      await _tripSafetyService.createTripDispute(
        rideId: widget.tripId,
        riderId: widget.riderId,
        driverId: widget.tripData['driver_id']?.toString() ?? '',
        serviceType: _serviceType.key,
        reason: _selectedReason,
        message: _messageController.text.trim(),
        source: 'rider_trip_report',
      );

      debugPrint('[TripReport] report saved reportId=${reportRef.key}');

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(payload);
    } catch (error, stackTrace) {
      debugPrint('[TripReport] submit failed: $error');
      debugPrintStack(
        label: '[TripReport] submit stack',
        stackTrace: stackTrace,
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to submit your report right now.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F2EA),
      appBar: AppBar(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        title: const Text('Report this trip'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 16,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _serviceType.detailLabel,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF8A6424),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Choose the reason that best matches the issue with this trip.',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.black.withValues(alpha: 0.7),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _reasonOptions
                    .map(
                      (reason) => ChoiceChip(
                        label: Text(
                          reason[0].toUpperCase() + reason.substring(1),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        selected: _selectedReason == reason,
                        selectedColor: _gold.withValues(alpha: 0.18),
                        side: BorderSide(
                          color: _selectedReason == reason
                              ? _gold
                              : Colors.black.withValues(alpha: 0.12),
                        ),
                        onSelected: _submitting
                            ? null
                            : (_) {
                                setState(() {
                                  _selectedReason = reason;
                                });
                              },
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _messageController,
                enabled: !_submitting,
                maxLines: 5,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Additional details (optional)',
                  labelStyle: TextStyle(
                    color: Colors.black.withValues(alpha: 0.6),
                  ),
                  hintText: 'Add anything support should know.',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: const BorderSide(color: _gold, width: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: _submitting ? null : _submitReport,
                child: _submitting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Text(
                        'Submit report',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
