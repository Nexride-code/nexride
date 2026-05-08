import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart' as rtdb;
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../support/driver_profile_support.dart';
import '../support/friendly_firebase_errors.dart';

class DriverSubscriptionPaymentScreen extends StatefulWidget {
  const DriverSubscriptionPaymentScreen({
    super.key,
    required this.driverId,
    required this.planType,
    required this.amountNgn,
  });

  final String driverId;
  final String planType;
  final int amountNgn;

  @override
  State<DriverSubscriptionPaymentScreen> createState() =>
      _DriverSubscriptionPaymentScreenState();
}

class _DriverSubscriptionPaymentScreenState
    extends State<DriverSubscriptionPaymentScreen> {
  static const Duration _windowDuration = Duration(minutes: 30);
  static const String _bankName = 'United Bank of Africa (UBA)';
  static const String _accountName = 'NEXRIDE DYNAMIC JOURNEY LTD';
  static const String _accountNumber = '1029983699';

  final ImagePicker _picker = ImagePicker();
  final rtdb.DatabaseReference _rootRef = rtdb.FirebaseDatabase.instance.ref();

  DateTime _expiresAt = DateTime.now().add(_windowDuration);
  Timer? _ticker;
  String _paymentReference = '';
  String? _pickedImagePath;
  String? _proofUrl;
  bool _uploadingProof = false;
  bool _submitting = false;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _resetWindow(showExpiredNotice: false);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Duration get _remaining {
    final diff = _expiresAt.difference(DateTime.now());
    if (diff.isNegative) {
      return Duration.zero;
    }
    return diff;
  }

  String _formatRemaining(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _buildReference() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'NEXSUB_${widget.driverId}_$ts';
  }

  void _resetWindow({required bool showExpiredNotice}) {
    _ticker?.cancel();
    final nextExpiry = DateTime.now().add(_windowDuration);
    setState(() {
      _expiresAt = nextExpiry;
      _paymentReference = _buildReference();
      _pickedImagePath = null;
      _proofUrl = null;
      _expired = false;
      _uploadingProof = false;
      _submitting = false;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      if (_remaining == Duration.zero) {
        _handleWindowExpired();
      } else {
        setState(() {});
      }
    });
    if (showExpiredNotice) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment window expired. Please try again.'),
        ),
      );
    }
  }

  void _handleWindowExpired() {
    _ticker?.cancel();
    setState(() {
      _expired = true;
    });
    _showExpiredDialog();
  }

  Future<void> _showExpiredDialog() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Payment window expired'),
        content: const Text('Payment window expired. Please try again.'),
        actions: <Widget>[
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _resetWindow(showExpiredNotice: false);
            },
            child: const Text('Restart'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickProofImage() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 88,
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _pickedImagePath = picked.path;
      _proofUrl = null;
    });
  }

  Future<void> _uploadProofImage() async {
    if (_pickedImagePath == null || _pickedImagePath!.isEmpty) {
      return;
    }
    setState(() {
      _uploadingProof = true;
    });
    try {
      final authUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      final targetUid = authUid.isNotEmpty ? authUid : widget.driverId.trim();
      if (targetUid.isEmpty) {
        throw StateError('missing_driver_uid_for_upload');
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final storagePath =
          'driver_documents/$targetUid/subscription_proof_$ts.jpg';
      final file = File(_pickedImagePath!);
      final size = await file.length();
      debugPrint(
        '[SUBSCRIPTION_UPLOAD] uid=$targetUid widgetDriverId=${widget.driverId} path=${file.path}, size: $size',
      );
      final ref = FirebaseStorage.instance.ref(storagePath);
      await ref.putFile(
        file,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: <String, String>{
            'driverId': widget.driverId,
            'uploadUid': targetUid,
            'planType': widget.planType,
            'kind': 'subscription_proof',
          },
        ),
      );
      final url = await ref.getDownloadURL();
      if (!mounted) {
        return;
      }
      setState(() {
        _proofUrl = url;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Proof uploaded. You can now submit.')),
      );
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        '[SUBSCRIPTION_UPLOAD][FIREBASE_STORAGE] code=${error.code} message=${error.message} plugin=${error.plugin}',
      );
      debugPrintStack(
        label: '[SUBSCRIPTION_UPLOAD][FIREBASE_STORAGE][STACK]',
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Upload failed (${error.code}): ${error.message ?? 'Please try again.'}',
          ),
        ),
      );
    } catch (error) {
      debugPrint('[SUBSCRIPTION_UPLOAD][ERROR] $error');
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyFirebaseError(error, debugLabel: 'subscription.uploadProof'),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _uploadingProof = false;
        });
      }
    }
  }

  Future<void> _submitRequest() async {
    if (_proofUrl == null || _proofUrl!.trim().isEmpty || _submitting) {
      return;
    }
    setState(() {
      _submitting = true;
    });
    try {
      final planLabel = widget.planType == 'weekly' ? 'Weekly' : 'Monthly';
      final updates = <String, dynamic>{
        'subscription_pending': true,
        'subscription_type': widget.planType,
        'subscription_amount': widget.amountNgn,
        'subscription_requested_at': rtdb.ServerValue.timestamp,
        'subscription_proof_url': _proofUrl!.trim(),
        'subscription_payment_reference': _paymentReference,
        'subscription_expires_at': null,
        'subscription_status': 'pending',
        'commission_exempt': false,
        'businessModel/selectedModel': 'subscription',
        'businessModel/commissionExempt': false,
        'businessModel/commission_exempt': false,
        'businessModel/subscription/status': 'pending_approval',
        'businessModel/subscription/paymentStatus': 'proof_submitted',
        'businessModel/subscription/planType': widget.planType,
        'businessModel/subscription/updatedAt': rtdb.ServerValue.timestamp,
        'businessModel/updatedAt': rtdb.ServerValue.timestamp,
        'updated_at': rtdb.ServerValue.timestamp,
      };
      await _rootRef.child('drivers/${widget.driverId}').update(updates);
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Subscription submitted'),
          content: Text(
            'Payment submitted — awaiting admin approval (usually within 2 hours).\n\nPlan: $planLabel ${formatDriverNairaAmount(widget.amountNgn)}',
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyFirebaseError(error, debugLabel: 'subscription.submit'),
          ),
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

  Future<void> _onBackPressed() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Payment window in progress'),
        content: const Text(
          'This screen cannot be dismissed while the 30-minute payment window is active. '
          'Please complete payment and submit proof before leaving.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_expired &&
        !_submitting &&
        !_uploadingProof &&
        (_proofUrl?.trim().isNotEmpty ?? false);
    final timerText = _formatRemaining(_remaining);
    final amountLabel = formatDriverNairaAmount(widget.amountNgn);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        unawaited(_onBackPressed());
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Subscription payment'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEEFC9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: <Widget>[
                    const Text(
                      'Time left',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      timerText,
                      style: const TextStyle(
                        fontSize: 46,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text(
                        'NexRide official bank details',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text('Bank: $_bankName'),
                      Text('Account Name: $_accountName'),
                      Text('Account Number: $_accountNumber'),
                      Text('Amount: $amountLabel'),
                      const SizedBox(height: 8),
                      SelectableText(
                        'Reference: $_paymentReference',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _expired || _uploadingProof ? null : _pickProofImage,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose payment proof image'),
              ),
              const SizedBox(height: 10),
              if (_pickedImagePath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(_pickedImagePath!),
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              if (_pickedImagePath != null) ...<Widget>[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed:
                      _expired || _uploadingProof ? null : _uploadProofImage,
                  icon: _uploadingProof
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload_outlined),
                  label: Text(
                    _proofUrl == null ? 'Upload proof' : 'Uploaded',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: canSubmit ? _submitRequest : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Submit subscription request'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
