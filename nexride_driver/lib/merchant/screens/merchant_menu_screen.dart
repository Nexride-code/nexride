import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../../admin/admin_config.dart';
import '../merchant_portal_functions.dart';
import '../merchant_portal_utils.dart';

/// Categories + items for the signed-in merchant (Phase 4B commerce).
class MerchantMenuScreen extends StatefulWidget {
  const MerchantMenuScreen({super.key});

  @override
  State<MerchantMenuScreen> createState() => _MerchantMenuScreenState();
}

class _MerchantMenuScreenState extends State<MerchantMenuScreen> {
  bool _loading = true;
  String? _err;
  List<Map<String, dynamic>> _categories = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _items = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final r = await MerchantPortalFunctions().merchantListMyMenu();
      if (!mpSuccess(r['success'])) {
        throw StateError(r['reason']?.toString() ?? 'load_failed');
      }
      final cats = <Map<String, dynamic>>[];
      if (r['categories'] is List) {
        for (final c in r['categories'] as List<dynamic>) {
          if (c is Map) {
            cats.add(c.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      final items = <Map<String, dynamic>>[];
      if (r['items'] is List) {
        for (final it in r['items'] as List<dynamic>) {
          if (it is Map) {
            items.add(it.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      }
      if (mounted) {
        setState(() {
          _categories = cats;
          _items = items;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _err = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _catId(Map<String, dynamic> c) =>
      (c['category_id'] ?? c['id'])?.toString() ?? '';

  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New category'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      ctrl.dispose();
      return;
    }
    try {
      final r = await MerchantPortalFunctions().merchantUpsertMenuCategory(<String, dynamic>{
        'name': ctrl.text.trim(),
      });
      ctrl.dispose();
      if (!mpSuccess(r['success'])) {
        throw StateError(r['reason']?.toString() ?? 'save_failed');
      }
      await _load();
    } catch (e) {
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _addOrEditItem({Map<String, dynamic>? existing}) async {
    final nameCtrl = TextEditingController(text: existing?['name']?.toString() ?? '');
    final priceCtrl = TextEditingController(
      text: existing != null ? '${existing['price_ngn'] ?? ''}' : '',
    );
    final prepCtrl = TextEditingController(
      text: existing != null ? '${existing['prep_time_min'] ?? 15}' : '15',
    );
    String? categoryId = existing?['category_id']?.toString();
    final itemId = existing != null
        ? (existing['item_id'] ?? existing['id'])?.toString()
        : null;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            title: Text(existing == null ? 'New item' : 'Edit item'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  DropdownButtonFormField<String>(
                    initialValue: categoryId != null &&
                            _categories.any((c) => _catId(c) == categoryId)
                        ? categoryId
                        : null,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: _categories
                        .map(
                          (c) => DropdownMenuItem<String>(
                            value: _catId(c),
                            child: Text(c['name']?.toString() ?? _catId(c)),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setLocal(() => categoryId = v),
                  ),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  TextField(
                    controller: priceCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Price (₦)'),
                  ),
                  TextField(
                    controller: prepCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Prep minutes'),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          );
        },
      ),
    );

    if (saved != true || !mounted) {
      nameCtrl.dispose();
      priceCtrl.dispose();
      prepCtrl.dispose();
      return;
    }
    final cid = categoryId ?? '';
    if (cid.isEmpty || nameCtrl.text.trim().length < 2) {
      nameCtrl.dispose();
      priceCtrl.dispose();
      prepCtrl.dispose();
      return;
    }
    try {
      final r = await MerchantPortalFunctions().merchantUpsertMenuItem(<String, dynamic>{
        if (itemId != null && itemId.isNotEmpty) 'item_id': itemId,
        'category_id': cid,
        'name': nameCtrl.text.trim(),
        'price_ngn': int.tryParse(priceCtrl.text.trim()) ?? 0,
        'prep_time_min': int.tryParse(prepCtrl.text.trim()) ?? 15,
      });
      if (!mpSuccess(r['success'])) {
        throw StateError(r['reason']?.toString() ?? 'save_failed');
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      nameCtrl.dispose();
      priceCtrl.dispose();
      prepCtrl.dispose();
    }
  }

  Future<void> _uploadItemPhoto(Map<String, dynamic> item) async {
    final merchantR = await MerchantPortalFunctions().merchantGetMyMerchant();
    if (!mpSuccess(merchantR['success']) || merchantR['merchant'] is! Map) {
      throw StateError('merchant_load_failed');
    }
    final m = merchantR['merchant'] as Map;
    final merchantId = m['merchant_id']?.toString() ?? '';
    final itemId = (item['item_id'] ?? item['id'])?.toString() ?? '';
    if (merchantId.isEmpty || itemId.isEmpty) {
      return;
    }
    final pick = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (pick == null || pick.files.isEmpty) {
      return;
    }
    final f = pick.files.first;
    final bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) {
      return;
    }
    final rawName = f.name.trim().isEmpty ? 'menu.jpg' : f.name.trim();
    final safe = rawName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_').split('/').last;
    final path = 'merchant_uploads/$merchantId/menu/$itemId/$safe';
    final ref = FirebaseStorage.instance.ref(path);
    await ref.putData(
      Uint8List.fromList(bytes),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    final url = await ref.getDownloadURL();
    final r = await MerchantPortalFunctions().merchantUpsertMenuItem(<String, dynamic>{
      'item_id': itemId,
      'category_id': item['category_id'],
      'name': item['name'],
      'price_ngn': item['price_ngn'],
      'prep_time_min': item['prep_time_min'] ?? 15,
      'image_url': url,
      'available': item['available'] != false,
      'stock_status': item['stock_status'] ?? 'in_stock',
    });
    if (!mpSuccess(r['success'])) {
      throw StateError(r['reason']?.toString() ?? 'upload_failed');
    }
    await _load();
  }

  Future<void> _toggleAvailability(Map<String, dynamic> item) async {
    final id = (item['item_id'] ?? item['id'])?.toString() ?? '';
    if (id.isEmpty) {
      return;
    }
    final currentlyOn = item['available'] != false;
    final r = await MerchantPortalFunctions().merchantUpsertMenuItem(<String, dynamic>{
      'item_id': id,
      'category_id': item['category_id'],
      'name': item['name'],
      'price_ngn': item['price_ngn'],
      'prep_time_min': item['prep_time_min'] ?? 15,
      'available': !currentlyOn,
      'stock_status': item['stock_status'] ?? 'in_stock',
      if (item['image_url'] != null) 'image_url': item['image_url'],
    });
    if (!mpSuccess(r['success'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['reason']?.toString() ?? 'update_failed')),
        );
      }
      return;
    }
    await _load();
  }

  Future<void> _archiveItem(Map<String, dynamic> item) async {
    final id = (item['item_id'] ?? item['id'])?.toString() ?? '';
    if (id.isEmpty) {
      return;
    }
    final r = await MerchantPortalFunctions().merchantArchiveMenuItem(<String, dynamic>{
      'item_id': id,
    });
    if (!mpSuccess(r['success'])) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r['reason']?.toString() ?? 'archive_failed')),
        );
      }
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final activeItems = _items
        .where((it) => it['archived_at'] == null)
        .toList(growable: false);
    final archivedItems = _items
        .where((it) => it['archived_at'] != null)
        .toList(growable: false);
    return Scaffold(
      backgroundColor: AdminThemeTokens.canvas,
      appBar: AppBar(
        title: const Text('Menu & catalog'),
        actions: <Widget>[
          IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCategory,
        icon: const Icon(Icons.folder_open),
        label: const Text('Category'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
          ? Center(child: Text(_err!))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _categories.isEmpty ? null : () => _addOrEditItem(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add item'),
                  ),
                ),
                const SizedBox(height: 12),
                ...activeItems.map((it) {
                  return Card(
                    child: ListTile(
                      title: Text(it['name']?.toString() ?? ''),
                      subtitle: Text(
                        '₦${it['price_ngn']} · ${it['available'] == false ? 'off' : 'on'} · '
                        '${it['stock_status'] ?? 'in_stock'}',
                      ),
                      isThreeLine: true,
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          try {
                            if (v == 'edit') {
                              await _addOrEditItem(existing: it);
                            } else if (v == 'photo') {
                              await _uploadItemPhoto(it);
                            } else if (v == 'toggle') {
                              await _toggleAvailability(it);
                            } else if (v == 'archive') {
                              await _archiveItem(it);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('$e')),
                              );
                            }
                          }
                        },
                        itemBuilder: (ctx) => <PopupMenuEntry<String>>[
                          const PopupMenuItem(value: 'edit', child: Text('Edit')),
                          const PopupMenuItem(value: 'photo', child: Text('Set photo')),
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(it['available'] == false ? 'Mark available' : 'Mark unavailable'),
                          ),
                          const PopupMenuItem(value: 'archive', child: Text('Archive')),
                        ],
                      ),
                    ),
                  );
                }),
                if (archivedItems.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 24),
                  const Text(
                    'Archived',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  ...archivedItems.map(
                    (it) => Card(
                      color: Colors.grey.shade200,
                      child: ListTile(
                        title: Text(it['name']?.toString() ?? ''),
                        subtitle: const Text('Archived'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
