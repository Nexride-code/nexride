import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/merchant_media_service.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';

class MenuItemEditScreen extends StatefulWidget {
  const MenuItemEditScreen({
    super.key,
    required this.categoryId,
    this.existing,
  });

  final String categoryId;
  final Map<String, dynamic>? existing;

  @override
  State<MenuItemEditScreen> createState() => _MenuItemEditScreenState();
}

class _MenuItemEditScreenState extends State<MenuItemEditScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _price = TextEditingController();
  final _imageUrl = TextEditingController();
  bool _available = true;
  bool _saving = false;
  bool _uploading = false;
  String? _pendingImagePath;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = '${e['name'] ?? ''}';
      _description.text = '${e['description'] ?? ''}';
      _price.text = '${e['price_ngn'] ?? ''}';
      _imageUrl.text = '${e['image_url'] ?? ''}';
      _available = e['available'] != false;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _price.dispose();
    _imageUrl.dispose();
    super.dispose();
  }

  String? get _itemId {
    final e = widget.existing;
    if (e == null) return null;
    final id = e['id'] ?? e['item_id'];
    if (id == null) return null;
    final s = '$id'.trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _pickPendingOrUpload() async {
    final id = _itemId;
    final m = context.read<MerchantAppState>().merchant;
    if (id == null || m == null) {
      final x = await MerchantMediaService.pickImage();
      if (x == null || !mounted) return;
      setState(() => _pendingImagePath = x.path);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo will upload after you save the item.')),
      );
      return;
    }
    setState(() => _uploading = true);
    try {
      final url = await MerchantMediaService.pickUploadAndAttach(
        gateway: context.read<MerchantAppState>().gateway,
        merchantId: m.merchantId,
        kind: 'item',
        entityId: id,
      );
      if (!mounted) return;
      if (url != null) {
        setState(() => _imageUrl.text = url);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Item image updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(nxUserFacingMessage(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final payload = <String, dynamic>{
        'category_id': widget.categoryId,
        'name': _name.text.trim(),
        'description': _description.text.trim(),
        'price_ngn': num.tryParse(_price.text.trim()) ?? 0,
        'available': _available,
        if (_imageUrl.text.trim().isNotEmpty) 'image_url': _imageUrl.text.trim(),
      };
      final id = widget.existing?['id'] ?? widget.existing?['item_id'];
      if (id != null && '$id'.isNotEmpty) {
        payload['item_id'] = id;
      }
      final res =
          await context.read<MerchantAppState>().gateway.merchantUpsertMenuItem(payload);
      if (!mounted) return;
      if (!nxSuccess(res['success'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Item could not be saved.',
              ),
            ),
          ),
        );
        return;
      }
      final newId = '${res['item_id'] ?? res['itemId'] ?? ''}'.trim();
      final path = _pendingImagePath;
      if (path != null && path.isNotEmpty && newId.isNotEmpty) {
        final m = context.read<MerchantAppState>().merchant;
        if (m != null) {
          try {
            final url = await MerchantMediaService.uploadLocalFileAndAttach(
              gateway: context.read<MerchantAppState>().gateway,
              merchantId: m.merchantId,
              kind: 'item',
              entityId: newId,
              localPath: path,
            );
            if (url != null && mounted) {
              setState(() => _imageUrl.text = url);
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(nxUserFacingMessage(e))),
              );
            }
          }
        }
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _archive() async {
    final id = widget.existing?['id'] ?? widget.existing?['item_id'];
    if (id == null) return;
    setState(() => _saving = true);
    try {
      final res = await context.read<MerchantAppState>().gateway.merchantArchiveMenuItem(<String, dynamic>{
        'item_id': id,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Item could not be archived.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasItemId = _itemId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add item' : 'Edit item'),
        actions: <Widget>[
          if (widget.existing != null)
            TextButton(
              onPressed: _saving ? null : _archive,
              child: const Text('Archive'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(
            controller: _description,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
          TextField(
            controller: _price,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Price (NGN, whole amount)'),
          ),
          FilledButton.tonal(
            onPressed: _uploading || _saving ? null : _pickPendingOrUpload,
            child: _uploading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(hasItemId ? 'Upload product photo' : 'Choose product photo (after save)'),
          ),
          if (_pendingImagePath != null && !hasItemId)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'A photo is ready to upload when you tap Save.',
                style: TextStyle(fontSize: 13),
              ),
            ),
          TextField(
            controller: _imageUrl,
            decoration: const InputDecoration(
              labelText: 'Image URL (optional)',
              helperText: 'Or paste an HTTPS image URL.',
            ),
          ),
          SwitchListTile(
            title: const Text('Available for ordering'),
            value: _available,
            onChanged: (v) => setState(() => _available = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save item'),
          ),
        ],
      ),
    );
  }
}
