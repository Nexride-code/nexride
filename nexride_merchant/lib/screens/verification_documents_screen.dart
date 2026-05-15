import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';

const _kDocTypes = <String>[
  'cac_document',
  'owner_id',
  'storefront_photo',
  'address_proof',
  'operating_license',
];

class VerificationDocumentsScreen extends StatefulWidget {
  const VerificationDocumentsScreen({super.key});

  @override
  State<VerificationDocumentsScreen> createState() => _VerificationDocumentsScreenState();
}

class _VerificationDocumentsScreenState extends State<VerificationDocumentsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _docs = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final gw = context.read<MerchantAppState>().gateway;
      final res = await gw.merchantListMyVerificationDocuments();
      if (res['success'] != true) {
        _error = nxMapFailureMessage(
          Map<String, dynamic>.from(res),
          'Documents could not be loaded.',
        );
        _docs = const <Map<String, dynamic>>[];
      } else {
        final raw = res['documents'];
        if (raw is List) {
          _docs = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false);
        } else {
          _docs = const <Map<String, dynamic>>[];
        }
      }
    } catch (e) {
      _error = nxUserFacingMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload(String documentType) async {
    if (!mounted) return;
    final state = context.read<MerchantAppState>();
    final mid = state.merchant?.merchantId ?? '';
    if (mid.isEmpty) return;
    final gateway = state.gateway;
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 82);
    if (x == null) return;
    final file = File(x.path);
    final name = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final path = 'merchant_uploads/$mid/verification/$documentType/$name';
    setState(() => _loading = true);
    try {
      final ref = FirebaseStorage.instance.ref(path);
      await ref.putFile(
        file,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      if (!mounted) return;
      final res = await gateway.merchantUploadVerificationDocument(<String, dynamic>{
        'document_type': documentType,
        'storage_path': path,
        'file_name': name,
        'content_type': 'image/jpeg',
      });
      if (!mounted) return;
      if (res['success'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Upload could not be completed.',
              ),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document submitted for review')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nxUserFacingMessage(e))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verification'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Upload',
            onPressed: () async {
              await showDialog<void>(
                context: context,
                builder: (ctx) => SimpleDialog(
                  title: const Text('Document type'),
                  children: <Widget>[
                    for (final t in _kDocTypes)
                      SimpleDialogOption(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _upload(t);
                        },
                        child: Text(t),
                      ),
                  ],
                ),
              );
            },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Column(
                  children: <Widget>[
                    NxInlineError(message: _error!),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _docs.length,
                    itemBuilder: (context, i) {
                      final d = _docs[i];
                      final t = '${d['document_type']}';
                      final st = '${d['status']}';
                      return Card(
                        child: ListTile(
                          title: Text(t),
                          subtitle: Text('Status: $st'),
                          trailing: IconButton(
                            icon: const Icon(Icons.upload_file_outlined),
                            onPressed: () => _upload(t),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
