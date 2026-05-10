import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../ride_type_screen.dart';
import '../services/rider_compliance_service.dart';

/// One-time selfie capture for regulatory identity checks.
class RiderSelfieVerificationScreen extends StatefulWidget {
  const RiderSelfieVerificationScreen({super.key});

  @override
  State<RiderSelfieVerificationScreen> createState() =>
      _RiderSelfieVerificationScreenState();
}

class _RiderSelfieVerificationScreenState
    extends State<RiderSelfieVerificationScreen> {
  static const Color _gold = Color(0xFFD4AF37);

  final ImagePicker _picker = ImagePicker();
  bool _uploading = false;

  Future<void> _takeAndUpload() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return;
    }

    setState(() => _uploading = true);
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 88,
      );
      if (photo == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Selfie is required before you can book a ride.'),
            ),
          );
        }
        return;
      }

      final file = File(photo.path);
      await RiderComplianceService.instance.uploadSelfieAndMarkPending(
        uid: user.uid,
        imageFile: file,
      );

      if (!mounted) {
        return;
      }

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text(
            'Thank you!',
            style: TextStyle(color: _gold),
          ),
          content: const Text(
            'Your selfie was sent for review. You can browse the app, but you '
            'cannot book rides or dispatch until NexRide staff approve your identity.',
            style: TextStyle(color: Colors.white70, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Continue', style: TextStyle(color: _gold)),
            ),
          ],
        ),
      );

      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => const RideTypeScreen(),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Upload failed. You can retry later from the home screen — '
              'you will need a selfie before booking. (${e.toString()})',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
      }
    }
  }

  void _skipToHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const RideTypeScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: _gold,
        title: const Text('Verify Your Identity'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            const Icon(Icons.camera_front_rounded, color: _gold, size: 56),
            const SizedBox(height: 24),
            const Text(
              'We require a one-time selfie to keep NexRide safe for everyone.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your photo is stored securely and reviewed by our team. '
              'You can still browse the app if you skip now — you will need to '
              'upload before your first ride or delivery request.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, height: 1.45),
            ),
            const Spacer(),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _uploading ? null : _takeAndUpload,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                child: _uploading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text(
                        'Take Selfie',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _uploading ? null : _skipToHome,
              child: const Text(
                'Continue without selfie',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
