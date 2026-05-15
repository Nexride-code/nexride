import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'services/rider_ride_cloud_functions_service.dart';
import 'services/nexride_official_bank_account_service.dart';
import 'support/friendly_firebase_errors.dart';

/// Mandatory bank-transfer receipt capture after trip completion.
class BankTransferReceiptScreen extends StatefulWidget {
  const BankTransferReceiptScreen({
    super.key,
    required this.rideId,
    this.onUploaded,
    this.onBlockedPopAttempt,
    this.bankTransferReference = '',
  });

  final String rideId;
  final VoidCallback? onUploaded;
  final String bankTransferReference;

  /// Parent should show a non-dismissible sheet / dialog.
  final VoidCallback? onBlockedPopAttempt;

  @override
  State<BankTransferReceiptScreen> createState() =>
      _BankTransferReceiptScreenState();
}

class _BankTransferReceiptScreenState extends State<BankTransferReceiptScreen> {
  final ImagePicker _picker = ImagePicker();
  bool _uploading = false;
  String? _pickedPath;
  String? _error;
  String _resolvedBankTransferReference = '';
  NexrideOfficialBankAccount? _officialBank;
  bool _officialBankLoaded = false;

  Future<void> _copyReference() async {
    final reference = _resolvedBankTransferReference.trim();
    if (reference.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: reference));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Payment reference copied')),
    );
  }

  @override
  void initState() {
    super.initState();
    _resolvedBankTransferReference = widget.bankTransferReference.trim();
    if (_resolvedBankTransferReference.isEmpty) {
      unawaited(_loadBankReferenceFromRide());
    }
    unawaited(_loadOfficialBank());
  }

  Future<void> _loadOfficialBank() async {
    try {
      final b = await NexrideOfficialBankAccountService.instance.fetch();
      if (!mounted) return;
      setState(() {
        _officialBank = b;
        _officialBankLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _officialBankLoaded = true;
      });
    }
  }

  Future<void> _loadBankReferenceFromRide() async {
    try {
      final snap = await FirebaseDatabase.instance
          .ref('ride_requests/${widget.rideId.trim()}')
          .get();
      if (!snap.exists || snap.value is! Map) {
        return;
      }
      final ride = Map<String, dynamic>.from(snap.value as Map);
      final ref =
          (ride['payment_reference']?.toString().trim().isNotEmpty == true
                  ? ride['payment_reference']
                  : ride['customer_transaction_reference'])
              ?.toString()
              .trim();
      if (!mounted || ref == null || ref.isEmpty) {
        return;
      }
      setState(() {
        _resolvedBankTransferReference = ref;
      });
    } catch (_) {}
  }

  String _bankInstructionsText() {
    final ref = _resolvedBankTransferReference;
    if (!_officialBankLoaded) {
      return 'Bank: loading…\n'
          'Account details: loading…\n'
          'Reference: $ref (include this exactly in your narration)\n'
          'Upload your payment proof after the trip to complete your booking.';
    }
    final ob = _officialBank;
    if (ob == null) {
      return 'Official bank details could not be loaded. Contact support@nexride.africa.\n'
          'Reference: $ref (include this exactly in your narration)\n'
          'Upload your payment proof after the trip to complete your booking.';
    }
    return 'Bank: ${ob.bankName}\n'
        'Account Name: ${ob.accountName}\n'
        'Account Number: ${ob.accountNumber}\n'
        'Reference: $ref (include this exactly in your narration)\n'
        'Upload your payment proof after the trip to complete your booking.';
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final x = await _picker.pickImage(
        source: source,
        maxWidth: 2000,
        maxHeight: 2000,
        imageQuality: 88,
      );
      final path = x?.path;
      if (path == null || path.isEmpty) {
        return;
      }
      setState(() {
        _pickedPath = path;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not open the photo picker. Please try again.';
      });
    }
  }

  Future<void> _upload() async {
    final user = FirebaseAuth.instance.currentUser;
    final path = _pickedPath;
    if (user == null || path == null || path.isEmpty) {
      setState(() {
        _error = 'Choose a clear photo of your transfer receipt first.';
      });
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final rideId = widget.rideId.trim();
      final uid = user.uid;
      final storagePath = 'receipts/$uid/$rideId/bank_transfer_receipt.jpg';
      final file = File(path);
      final ref = FirebaseStorage.instance.ref().child(storagePath);
      await ref.putFile(
        file,
        SettableMetadata(
          contentType: 'image/jpeg',
          customMetadata: <String, String>{
            'rideId': rideId,
            'riderId': uid,
            'kind': 'bank_transfer_receipt',
          },
        ),
      );
      final url = await ref.getDownloadURL();
      final now = DateTime.now().millisecondsSinceEpoch;
      final patchRes =
          await RiderRideCloudFunctionsService.instance.patchRideRequestMetadata(
        rideId: rideId,
        patch: <String, dynamic>{
          'bank_transfer_receipt_url': url.toString(),
          'receipt_uploaded': true,
          'bank_transfer_receipt_uploaded_at': now,
        },
      );
      if (!riderRideCallableSucceeded(patchRes)) {
        if (kDebugMode) {
          debugPrint(
            '[BankReceipt] patch failed raw=$patchRes',
          );
        }
        if (!mounted) {
          return;
        }
        setState(() {
          _uploading = false;
          _error = friendlyCallableReason(
            patchRes,
            fallback: 'Could not save your receipt. Please try again.',
          );
        });
        return;
      }
      await FirebaseDatabase.instance
          .ref('users/$uid/pending_bank_transfer_receipt_ride_id')
          .remove();
      if (!mounted) {
        return;
      }
      widget.onUploaded?.call();
      Navigator.of(context).pop(true);
    } catch (e, stackTrace) {
      debugPrint('[BankReceipt] upload failed raw=$e');
      debugPrintStack(label: '[BankReceipt] stack', stackTrace: stackTrace);
      if (mounted) {
        setState(() {
          _uploading = false;
          _error = friendlyFirebaseError(e, debugLabel: 'BankReceipt.upload');
        });
      } else {
        _uploading = false;
      }
    }
  }

  void _onPopInvoked(bool didPop, dynamic result) {
    if (didPop) {
      return;
    }
    widget.onBlockedPopAttempt?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<Object?>(
      canPop: !_uploading,
      onPopInvokedWithResult: _onPopInvoked,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bank transfer receipt'),
          automaticallyImplyLeading: !_uploading,
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_resolvedBankTransferReference.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4D6),
                      border: Border.all(color: const Color(0xFFE7C776)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bank Transfer Instructions',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: const Color(0xFF5F4A16),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _bankInstructionsText(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF6B5A2B),
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFFBEE),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFFE2C476),
                                  ),
                                ),
                                child: Text(
                                  _resolvedBankTransferReference,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 13,
                                    color: Color(0xFF4D3E1A),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _copyReference,
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('Copy'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF6C551C),
                                side: const BorderSide(
                                  color: Color(0xFFD6B563),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                Text(
                  'Upload a clear photo of your bank transfer receipt so we can reconcile this trip.',
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                if (_pickedPath != null)
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(_pickedPath!),
                        fit: BoxFit.contain,
                      ),
                    ),
                  )
                else
                  const Expanded(
                    child: Center(
                      child: Icon(
                        Icons.receipt_long_outlined,
                        size: 72,
                        color: Colors.black38,
                      ),
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _uploading
                            ? null
                            : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Camera'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _uploading
                            ? null
                            : () => _pick(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Gallery'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _uploading ? null : _upload,
                  child: _uploading
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Upload receipt'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
