import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/merchant_portal_access.dart';
import '../services/merchant_connectivity.dart';
import '../state/merchant_app_state.dart';
import '../utils/nx_callable_messages.dart';
import '../widgets/nx_feedback.dart';
import 'menu_item_edit_screen.dart';

class MenuItemsScreen extends StatefulWidget {
  const MenuItemsScreen({
    super.key,
    required this.categoryId,
    required this.categoryName,
  });

  final String categoryId;
  final String categoryName;

  @override
  State<MenuItemsScreen> createState() => _MenuItemsScreenState();
}

class _MenuItemsScreenState extends State<MenuItemsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  String? _itemCursor;
  bool _hasMoreItems = false;
  bool _loadingMore = false;
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearchChanged);
    unawaited(_load(append: false));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(_load(append: false));
    });
  }

  Future<void> _load({required bool append}) async {
    if (!append) {
      setState(() {
        _loading = true;
        _error = null;
        _items = <Map<String, dynamic>>[];
        _itemCursor = null;
        _hasMoreItems = false;
      });
    } else {
      if (_loadingMore || !_hasMoreItems) return;
      setState(() => _loadingMore = true);
    }
    try {
      final gw = context.read<MerchantAppState>().gateway;
      final q = _search.text.trim();
      final res = await gw.merchantListMyMenuPage(<String, dynamic>{
        'items_category_id': widget.categoryId,
        'items_limit': 35,
        if (append && (_itemCursor ?? '').isNotEmpty) 'items_cursor': _itemCursor,
        if (q.isNotEmpty) 'items_search': q,
      });
      if (res['success'] != true) {
        final msg = nxMapFailureMessage(
          Map<String, dynamic>.from(res),
          'Menu could not be loaded.',
        );
        if (!append) {
          _error = msg;
          _items = const <Map<String, dynamic>>[];
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
      } else {
        final raw = res['items'];
        List<Map<String, dynamic>> chunk = const <Map<String, dynamic>>[];
        if (raw is List) {
          chunk = raw
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((row) => row['archived_at'] == null)
              .toList(growable: false);
        }
        _hasMoreItems = res['has_more_items'] == true;
        final next = '${res['items_next_cursor'] ?? ''}'.trim();
        _itemCursor = next.isEmpty ? null : next;
        if (append) {
          final merged = <Map<String, dynamic>>[..._items];
          for (final row in chunk) {
            final id = '${row['id'] ?? row['item_id'] ?? ''}';
            if (id.isEmpty || merged.any((x) => '${x['id'] ?? x['item_id']}' == id)) continue;
            merged.add(row);
          }
          _items = merged;
        } else {
          _items = chunk;
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
    if (!_hasMoreItems || _loadingMore || _loading) return;
    await _load(append: true);
  }

  @override
  Widget build(BuildContext context) {
    final online = context.watch<MerchantConnectivity>().online;
    final merchant = context.watch<MerchantAppState>().merchant;
    final canEdit = MerchantPortalAccess.canEditMenu(merchant);

    return Scaffold(
      appBar: AppBar(title: Text(widget.categoryName)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: !online || !canEdit || _loading
            ? null
            : () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MenuItemEditScreen(
                      categoryId: widget.categoryId,
                    ),
                  ),
                );
                await _load(append: false);
              },
        icon: const Icon(Icons.add),
        label: const Text('Item'),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search items in this category',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? ListView(
                        padding: const EdgeInsets.all(24),
                        children: <Widget>[
                          NxInlineError(message: _error!),
                          TextButton(onPressed: () => _load(append: false), child: const Text('Retry')),
                        ],
                      )
                    : RefreshIndicator(
                        onRefresh: () => _load(append: false),
                        child: _items.isEmpty
                            ? ListView(
                                children: const <Widget>[
                                  SizedBox(height: 120),
                                  NxEmptyState(title: 'No items in this category'),
                                ],
                              )
                            : NotificationListener<ScrollNotification>(
                                onNotification: (ScrollNotification n) {
                                  if (n.metrics.pixels > n.metrics.maxScrollExtent - 200) {
                                    unawaited(_maybeLoadMore());
                                  }
                                  return false;
                                },
                                child: ListView.builder(
                                  padding: const EdgeInsets.all(12),
                                  itemCount: _items.length + (_hasMoreItems ? 1 : 0),
                                  itemBuilder: (context, i) {
                                    if (i >= _items.length) {
                                      return const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Center(
                                          child: SizedBox(
                                            height: 28,
                                            width: 28,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          ),
                                        ),
                                      );
                                    }
                                    final it = _items[i];
                                    final img = it['image_url']?.toString();
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
                                                  errorBuilder: (_, __, ___) =>
                                                      const Icon(Icons.fastfood_outlined),
                                                ),
                                              )
                                            : const Icon(Icons.fastfood_outlined),
                                        title: Text('${it['name']}'),
                                        subtitle: Text(
                                          '₦${it['price_ngn']} • ${it['available'] == false ? 'Unavailable' : 'Available'}',
                                        ),
                                        onTap: !canEdit || !online
                                            ? null
                                            : () async {
                                                await Navigator.of(context).push(
                                                  MaterialPageRoute<void>(
                                                    builder: (_) => MenuItemEditScreen(
                                                      categoryId: widget.categoryId,
                                                      existing: it,
                                                    ),
                                                  ),
                                                );
                                                await _load(append: false);
                                              },
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
          ),
        ],
      ),
    );
  }
}
