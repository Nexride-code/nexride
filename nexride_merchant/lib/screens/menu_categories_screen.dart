import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_portal_access.dart';
import '../services/merchant_connectivity.dart';
import '../services/merchant_media_service.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';
import 'menu_items_screen.dart';

class MenuCategoriesScreen extends StatefulWidget {
  const MenuCategoriesScreen({super.key});

  @override
  State<MenuCategoriesScreen> createState() => _MenuCategoriesScreenState();
}

class _MenuCategoriesScreenState extends State<MenuCategoriesScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _cats = <Map<String, dynamic>>[];
  bool _mutating = false;
  String? _catCursor;
  bool _hasMoreCategories = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load(append: false);
  }

  Future<void> _load({required bool append}) async {
    if (!append) {
      setState(() {
        _loading = true;
        _error = null;
        _cats = <Map<String, dynamic>>[];
        _catCursor = null;
        _hasMoreCategories = false;
      });
    } else {
      if (_loadingMore || !_hasMoreCategories) return;
      setState(() => _loadingMore = true);
    }
    try {
      final gw = context.read<MerchantAppState>().gateway;
      final payload = <String, dynamic>{
        'categories_limit': 28,
        if (append && (_catCursor ?? '').isNotEmpty) 'categories_cursor': _catCursor,
      };
      final res = await gw.merchantListMyMenuPage(payload);
      if (!nxSuccess(res['success'])) {
        final msg = nxMapFailureMessage(
          Map<String, dynamic>.from(res),
          'Menu could not be loaded.',
        );
        if (!append) {
          _error = msg;
          _cats = const <Map<String, dynamic>>[];
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
      } else {
        final raw = res['categories'];
        List<Map<String, dynamic>> chunk = const <Map<String, dynamic>>[];
        if (raw is List) {
          chunk = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList(growable: false);
        }
        _hasMoreCategories = res['has_more_categories'] == true;
        final next = '${res['categories_next_cursor'] ?? ''}'.trim();
        _catCursor = next.isEmpty ? null : next;
        if (append) {
          _cats = <Map<String, dynamic>>[..._cats, ...chunk];
        } else {
          _cats = chunk;
        }
      }
    } catch (e) {
      if (!append) {
        _error = nxUserFacingMessage(e);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(nxUserFacingMessage(e))));
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  Future<void> _maybeLoadMore() async {
    if (!_hasMoreCategories || _loadingMore || _loading) return;
    await _load(append: true);
  }

  Future<void> _addCategory() async {
    final nameCtrl = TextEditingController();
    String? pickedImagePath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New category'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final x = await MerchantMediaService.pickImage();
                    if (x == null) return;
                    setLocal(() => pickedImagePath = x.path);
                  },
                  icon: const Icon(Icons.photo_outlined),
                  label: Text(
                    pickedImagePath == null ? 'Optional cover photo' : 'Cover photo selected',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    if (name.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a category name (at least 2 characters).')),
        );
      }
      return;
    }
    setState(() => _mutating = true);
    try {
      final gw = context.read<MerchantAppState>().gateway;
      final res = await gw.merchantUpsertMenuCategory(<String, dynamic>{
        'name': name,
        'sort_order': _cats.length,
      });
      if (!mounted) return;
      if (!nxSuccess(res['success'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Category could not be created.',
              ),
            ),
          ),
        );
        return;
      }
      final newId = '${res['category_id'] ?? res['categoryId'] ?? ''}'.trim();
      if (newId.isNotEmpty && pickedImagePath != null && pickedImagePath!.isNotEmpty) {
        final m = context.read<MerchantAppState>().merchant;
        if (m != null) {
          try {
            await MerchantMediaService.uploadLocalFileAndAttach(
              gateway: gw,
              merchantId: m.merchantId,
              kind: 'category',
              entityId: newId,
              localPath: pickedImagePath!,
            );
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(nxUserFacingMessage(e))),
              );
            }
          }
        }
      }
      await _load(append: false);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _editCategory(Map<String, dynamic> row) async {
    final id = '${row['id'] ?? row['category_id'] ?? ''}';
    final nameCtrl = TextEditingController(text: '${row['name'] ?? ''}');
    final sortCtrl = TextEditingController(text: '${row['sort_order'] ?? 0}');
    var active = row['active'] != false;
    final state = context.read<MerchantAppState>();
    final m = state.merchant;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Edit category'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
                TextField(
                  controller: sortCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Sort order'),
                ),
                SwitchListTile(
                  title: const Text('Active (visible in rider menu)'),
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                ),
                if (m != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      onPressed: () async {
                        try {
                          await MerchantMediaService.pickUploadAndAttach(
                            gateway: state.gateway,
                            merchantId: m.merchantId,
                            kind: 'category',
                            entityId: id,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Category image updated')),
                          );
                          await _load(append: false);
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(nxUserFacingMessage(e))),
                          );
                        }
                      },
                      child: const Text('Upload / change image'),
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _mutating = true);
    try {
      final res = await state.gateway.merchantUpsertMenuCategory(<String, dynamic>{
        'category_id': id,
        'name': nameCtrl.text.trim(),
        'sort_order': num.tryParse(sortCtrl.text.trim()) ?? 0,
        'active': active,
      });
      if (!mounted) return;
      if (!nxSuccess(res['success'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Category could not be updated.',
              ),
            ),
          ),
        );
        return;
      }
      await _load(append: false);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _archiveCategory(String id) async {
    Map<String, dynamic>? row;
    for (final c in _cats) {
      if ('${c['id'] ?? c['category_id']}' == id) {
        row = c;
        break;
      }
    }
    if (row == null) return;
    setState(() => _mutating = true);
    try {
      final res = await context.read<MerchantAppState>().gateway.merchantUpsertMenuCategory(<String, dynamic>{
        'category_id': id,
        'name': '${row['name'] ?? 'Category'}',
        'sort_order': num.tryParse('${row['sort_order'] ?? 0}') ?? 0,
        'active': false,
      });
      if (!mounted) return;
      if (!nxSuccess(res['success'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Category could not be archived.',
              ),
            ),
          ),
        );
        return;
      }
      await _load(append: false);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _deleteHard(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete category permanently?'),
        content: const Text(
          'This removes the category document. Items should be archived first.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _mutating = true);
    try {
      final res = await context.read<MerchantAppState>().gateway.merchantDeleteMenuCategory(<String, dynamic>{
        'category_id': id,
      });
      if (!mounted) return;
      if (!nxSuccess(res['success'])) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nxMapFailureMessage(
                Map<String, dynamic>.from(res),
                'Category could not be deleted.',
              ),
            ),
          ),
        );
        return;
      }
      await _load(append: false);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = context.watch<MerchantConnectivity>().online;
    final merchant = context.watch<MerchantAppState>().merchant;
    final canEdit = MerchantPortalAccess.canEditMenu(merchant);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Column(
        children: <Widget>[
          NxInlineError(message: _error!),
          TextButton(onPressed: () => _load(append: false), child: const Text('Retry')),
        ],
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: !online || !canEdit || _mutating ? null : _addCategory,
        icon: const Icon(Icons.add),
        label: const Text('Category'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(append: false),
        child: _cats.isEmpty
            ? ListView(
                children: const <Widget>[
                  SizedBox(height: 120),
                  NxEmptyState(
                    title: 'No menu categories',
                    subtitle: 'Create a category, then add items.',
                  ),
                ],
              )
            : NotificationListener<ScrollNotification>(
                onNotification: (ScrollNotification n) {
                  if (n.metrics.pixels > n.metrics.maxScrollExtent - 220) {
                    unawaited(_maybeLoadMore());
                  }
                  return false;
                },
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _cats.length + (_hasMoreCategories ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= _cats.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: SizedBox(height: 28, width: 28, child: CircularProgressIndicator(strokeWidth: 2))),
                      );
                    }
                    final c = _cats[i];
                    final id = '${c['id'] ?? c['category_id'] ?? ''}';
                    final name = '${c['name'] ?? 'Category'}';
                    final inactive = c['active'] == false;
                    final img = c['image_url']?.toString();
                    return Card(
                      child: ListTile(
                        leading: img != null && img.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(
                                  img,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.category_outlined),
                                ),
                              )
                            : const Icon(Icons.category_outlined),
                        title: Text(name),
                        subtitle: Text(
                          inactive ? 'Archived (hidden from rider menu)' : 'ID: $id',
                        ),
                        trailing: !canEdit || !online
                            ? null
                            : PopupMenuButton<String>(
                                onSelected: (v) async {
                                  switch (v) {
                                    case 'edit':
                                      await _editCategory(c);
                                    case 'archive':
                                      await _archiveCategory(id);
                                    case 'delete':
                                      await _deleteHard(id);
                                  }
                                },
                                itemBuilder: (ctx) => const <PopupMenuEntry<String>>[
                                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                                  PopupMenuItem(value: 'archive', child: Text('Archive / hide')),
                                  PopupMenuItem(value: 'delete', child: Text('Delete permanently')),
                                ],
                              ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => MenuItemsScreen(
                                categoryId: id,
                                categoryName: name,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
