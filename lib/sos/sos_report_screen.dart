import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../safe_share_origin.dart';
import 'emergency_contact_service.dart';
import 'nigeria_police_contacts.dart';

class SosReportScreen extends StatefulWidget {
  const SosReportScreen({
    super.key,
    required this.rideId,
    required this.riderId,
    required this.driverId,
    required this.tripStatus,
    required this.pickupLabel,
    required this.destinationLabel,
    this.pickupLat,
    this.pickupLng,
    this.destinationLat,
    this.destinationLng,
    this.currentLat,
    this.currentLng,
    required this.onShareLiveTrip,
    this.shareButtonKey,
  });

  final String rideId;
  final String riderId;
  final String driverId;
  final String tripStatus;
  final String pickupLabel;
  final String destinationLabel;
  final double? pickupLat;
  final double? pickupLng;
  final double? destinationLat;
  final double? destinationLng;
  final double? currentLat;
  final double? currentLng;
  final Future<void> Function(Rect shareOrigin) onShareLiveTrip;
  final GlobalKey? shareButtonKey;

  @override
  State<SosReportScreen> createState() => _SosReportScreenState();
}

class _SosReportScreenState extends State<SosReportScreen> {
  final _descriptionController = TextEditingController();
  final _contactNameController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  final _contactRelationshipController = TextEditingController();

  final _contactService = EmergencyContactService();
  EmergencyContact? _emergencyContact;
  String _emergencyType = 'safety_concern';
  String? _selectedPoliceState;
  bool _submitInFlight = false;
  bool _loadingContact = true;

  @override
  void initState() {
    super.initState();
    debugPrint('SOS_OPEN_REPORT_PAGE rideId=${widget.rideId}');
    unawaited(_loadEmergencyContact());
  }

  Future<void> _loadEmergencyContact() async {
    final uid = widget.riderId.isNotEmpty
        ? widget.riderId
        : (FirebaseAuth.instance.currentUser?.uid ?? '');
    if (uid.isEmpty) {
      if (mounted) {
        setState(() => _loadingContact = false);
      }
      return;
    }
    try {
      final contact = await _contactService.load(uid);
      if (!mounted) {
        return;
      }
      setState(() {
        _emergencyContact = contact;
        _loadingContact = false;
        if (contact != null) {
          _contactNameController.text = contact.name;
          _contactPhoneController.text = contact.phone;
          _contactRelationshipController.text = contact.relationship;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingContact = false);
      }
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    _contactRelationshipController.dispose();
    super.dispose();
  }

  Future<void> _submitReport() async {
    if (_submitInFlight) {
      return;
    }
    final riderId = widget.riderId.isNotEmpty
        ? widget.riderId
        : (FirebaseAuth.instance.currentUser?.uid ?? '');
    if (riderId.isEmpty || widget.rideId.isEmpty) {
      _showMessage('Sign in to submit an SOS report.');
      return;
    }
    setState(() => _submitInFlight = true);
    debugPrint('SOS_REPORT_SUBMIT_START rideId=${widget.rideId}');
    try {
      final reportRef =
          rtdb.FirebaseDatabase.instance.ref('sos_reports/${widget.rideId}').push();
      final reportId = reportRef.key;
      if (reportId == null || reportId.isEmpty) {
        throw StateError('report_id_unavailable');
      }
      final location = <String, dynamic>{};
      if (widget.currentLat != null && widget.currentLng != null) {
        location['lat'] = widget.currentLat;
        location['lng'] = widget.currentLng;
      }
      await reportRef.set(<String, dynamic>{
        'reportId': reportId,
        'rideId': widget.rideId,
        'riderId': riderId,
        'driverId': widget.driverId,
        'status': 'open',
        'type': _emergencyType,
        'description': _descriptionController.text.trim(),
        'tripStatus': widget.tripStatus,
        'pickup': widget.pickupLabel,
        'destination': widget.destinationLabel,
        'location': location,
        'createdAt': rtdb.ServerValue.timestamp,
      });
      debugPrint('SOS_REPORT_SUBMIT_OK rideId=${widget.rideId} reportId=$reportId');
      if (!mounted) {
        return;
      }
      _showMessage('SOS report submitted. Our team has been alerted.');
    } catch (error) {
      _showMessage('Unable to submit SOS report right now. ($error)');
    } finally {
      if (mounted) {
        setState(() => _submitInFlight = false);
      }
    }
  }

  Future<void> _saveEmergencyContact() async {
    final uid = widget.riderId.isNotEmpty
        ? widget.riderId
        : (FirebaseAuth.instance.currentUser?.uid ?? '');
    if (uid.isEmpty) {
      _showMessage('Sign in to save an emergency contact.');
      return;
    }
    final name = _contactNameController.text.trim();
    final phone = _contactPhoneController.text.trim();
    if (name.isEmpty || phone.isEmpty) {
      _showMessage('Enter contact name and phone number.');
      return;
    }
    final contact = EmergencyContact(
      name: name,
      phone: phone,
      relationship: _contactRelationshipController.text.trim(),
    );
    await _contactService.save(uid, contact);
    if (!mounted) {
      return;
    }
    setState(() => _emergencyContact = contact);
    _showMessage('Emergency contact saved.');
  }

  Future<void> _dialPhone(String raw, {required String logTag}) async {
    debugPrint('$logTag phone=$raw rideId=${widget.rideId}');
    final tel = sanitizePhoneForDial(raw);
    if (tel.isEmpty) {
      _showMessage('Phone number is not valid.');
      return;
    }
    final uri = Uri(scheme: 'tel', path: tel);
    if (!await launchUrl(uri)) {
      _showMessage('Unable to open the phone dialer.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  NigeriaPoliceContact? _selectedPoliceContact() {
    final state = _selectedPoliceState;
    if (state == null || state.isEmpty) {
      return null;
    }
    for (final contact in nigeriaPoliceContacts) {
      if (contact.state == state) {
        return contact;
      }
    }
    return null;
  }

  Future<void> _dialSelectedPoliceContact() async {
    final police = _selectedPoliceContact();
    if (police == null) {
      _showMessage('Select a state police contact first.');
      return;
    }
    await _dialPhone(police.phone, logTag: 'SOS_DIAL_POLICE_START');
  }

  @override
  Widget build(BuildContext context) {
    final police = _selectedPoliceContact();

    return Scaffold(
      appBar: AppBar(
        title: const Text('SOS report'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Ride ${widget.rideId}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text('Status: ${widget.tripStatus}'),
          Text('Pickup: ${widget.pickupLabel}'),
          Text('Destination: ${widget.destinationLabel}'),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: _emergencyType,
            decoration: const InputDecoration(labelText: 'Emergency type'),
            items: const [
              DropdownMenuItem(value: 'safety_concern', child: Text('Safety concern')),
              DropdownMenuItem(value: 'accident', child: Text('Accident')),
              DropdownMenuItem(value: 'harassment', child: Text('Harassment')),
              DropdownMenuItem(value: 'medical', child: Text('Medical')),
              DropdownMenuItem(value: 'other', child: Text('Other')),
            ],
            onChanged: (v) {
              if (v == null) {
                return;
              }
              setState(() => _emergencyType = v);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'What happened? Include landmarks if you can.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _submitInFlight ? null : _submitReport,
            icon: const Icon(Icons.report),
            label: Text(_submitInFlight ? 'Submitting…' : 'Submit SOS report'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: widget.shareButtonKey,
            onPressed: () async {
              debugPrint('SOS_SHARE_TRIP_START rideId=${widget.rideId}');
              final origin = safeShareOrigin(
                context,
                buttonKey: widget.shareButtonKey,
              );
              await widget.onShareLiveTrip(origin);
              debugPrint('SOS_SHARE_TRIP_OK rideId=${widget.rideId}');
            },
            icon: const Icon(Icons.share),
            label: const Text('Share live trip'),
          ),
          const SizedBox(height: 24),
          Text(
            'Emergency contact',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (_loadingContact)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            )
          else if (_emergencyContact != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_emergencyContact!.name),
              subtitle: Text(
                '${_emergencyContact!.phone} · ${_emergencyContact!.relationship}',
              ),
            ),
          TextField(
            controller: _contactNameController,
            decoration: const InputDecoration(labelText: 'Contact name'),
          ),
          TextField(
            controller: _contactPhoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Contact phone'),
          ),
          TextField(
            controller: _contactRelationshipController,
            decoration: const InputDecoration(labelText: 'Relationship'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saveEmergencyContact,
                  child: const Text('Save contact'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final phone = _emergencyContact?.phone ??
                        _contactPhoneController.text.trim();
                    if (phone.isEmpty) {
                      _showMessage(
                        'Add an emergency contact first, or enter a phone number.',
                      );
                      return;
                    }
                    unawaited(
                      _dialPhone(
                        phone,
                        logTag: 'SOS_DIAL_CONTACT_START',
                      ),
                    );
                  },
                  child: const Text('Call contact'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Nigeria police contacts',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          DropdownButtonFormField<String>(
            value: _selectedPoliceState,
            decoration: const InputDecoration(labelText: 'State'),
            items: nigeriaPoliceContacts
                .map(
                  (c) => DropdownMenuItem(
                    value: c.state,
                    child: Text(c.state),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _selectedPoliceState = v),
          ),
          if (police != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(police.label),
              subtitle: Text(police.phone),
            ),
          FilledButton.icon(
            onPressed: police == null ? null : () => unawaited(_dialSelectedPoliceContact()),
            icon: const Icon(Icons.local_police),
            label: const Text('Dial selected police contact'),
          ),
        ],
      ),
    );
  }
}
