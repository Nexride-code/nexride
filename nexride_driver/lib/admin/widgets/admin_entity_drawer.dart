import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../admin_config.dart';
import '../platform/admin_entity_cache_policy.dart';
import '../utils/admin_url_sync.dart' as admin_url_sync;
import 'admin_entity_drawer_controller.dart';

/// Tab definition for [AdminEntityDrawer] (entity-agnostic shell).
@immutable
class AdminEntityTabSpec {
  const AdminEntityTabSpec({
    required this.id,
    required this.label,
    this.icon,
  });

  final String id;
  final String label;
  final IconData? icon;
}

/// Lazy body loader for a single tab id. Must return a **small** widget tree;
/// heavy lists should paginate internally.
typedef AdminEntityTabBodyLoader = Future<Widget> Function(String tabId);

/// Placeholder while a tab body is loading (avoid unbounded spinners on slow tabs).
class AdminEntityTabSkeleton extends StatelessWidget {
  const AdminEntityTabSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SkelLine(width: 320, height: 14, margin: EdgeInsets.only(bottom: 10)),
        _SkelLine(width: 200, height: 14, margin: EdgeInsets.only(bottom: 10)),
        _SkelLine(width: 280, height: 12, margin: EdgeInsets.only(bottom: 8)),
        _SkelLine(width: 300, height: 12, margin: EdgeInsets.only(bottom: 8)),
        _SkelLine(width: 140, height: 12, margin: EdgeInsets.zero),
      ],
    );
  }
}

class _SkelLine extends StatelessWidget {
  const _SkelLine({
    required this.width,
    required this.height,
    required this.margin,
  });

  final double width;
  final double height;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFFE8E4DC),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}

/// Unified operations drawer: lazy tabs, cached tab bodies, responsive layout.
///
/// Logs: `[AdminEntity]`, `[AdminPerf][DRAWER_OPEN_MS]`, `[AdminPerf][TAB_LOAD_MS]`,
/// `[AdminPerf][DRAWER_DISPOSE]`, cache telemetry (Phase 3W / 3Y).
class AdminEntityDrawer extends StatefulWidget {
  const AdminEntityDrawer({
    required this.entityType,
    required this.entityId,
    required this.title,
    required this.subtitle,
    required this.tabs,
    required this.loadBody,
    super.key,
    this.onClose,
    this.controller,
    this.debugOpenStartedMs,
    this.tabStaleAfter,
    this.cachePolicy,
    this.drawerSequence = 0,
    this.syncBrowserHistory = false,
    this.initialTabIndex = 0,
  });

  final String entityType;
  final String entityId;
  final String title;
  final String subtitle;
  final List<AdminEntityTabSpec> tabs;
  final AdminEntityTabBodyLoader loadBody;
  final VoidCallback? onClose;
  final AdminEntityDrawerController? controller;
  final int? debugOpenStartedMs;
  final Duration? Function(String tabId)? tabStaleAfter;
  final AdminEntityCachePolicy? cachePolicy;
  final int drawerSequence;
  final bool syncBrowserHistory;
  final int initialTabIndex;

  static const int maxCachedTabs = 8;
  static int _openDrawerDepth = 0;

  /// Desktop / tablet: end-aligned sheet. Narrow: near-full-height modal with
  /// drag handle (dispatch-style).
  static Future<void> present(
    BuildContext context, {
    required String entityType,
    required String entityId,
    required String title,
    String subtitle = '',
    required List<AdminEntityTabSpec> tabs,
    required AdminEntityTabBodyLoader loadBody,
    AdminEntityDrawerController? controller,
    int? debugOpenStartedMs,
    Duration? Function(String tabId)? tabStaleAfter,
    AdminEntityCachePolicy? cachePolicy,
    bool syncBrowserHistory = false,
    int initialTabIndex = 0,
  }) {
    final int t0 = debugOpenStartedMs ?? DateTime.now().millisecondsSinceEpoch;
    final int seq = ++_presentSeq;
    _openDrawerDepth += 1;
    if (_openDrawerDepth > 1) {
      debugPrint(
        '[AdminEntity] concurrent_drawer_warning depth=$_openDrawerDepth seq=$seq',
      );
    }
    debugPrint(
      '[AdminEntity] open type=$entityType id=$entityId tabs=${tabs.length} seq=$seq',
    );
    if (syncBrowserHistory && kIsWeb) {
      final String? tabId =
          initialTabIndex > 0 && initialTabIndex < tabs.length
              ? tabs[initialTabIndex].id
              : null;
      admin_url_sync.adminUrlSyncDriverOpen(entityId, tab: tabId);
    }
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (
        BuildContext dialogContext,
        Animation<double> animation,
        Animation<double> secondaryAnimation,
      ) {
        final Widget child = AdminEntityDrawer(
          entityType: entityType,
          entityId: entityId,
          title: title,
          subtitle: subtitle,
          tabs: tabs,
          loadBody: loadBody,
          controller: controller,
          debugOpenStartedMs: t0,
          tabStaleAfter: tabStaleAfter,
          cachePolicy: cachePolicy,
          drawerSequence: seq,
          syncBrowserHistory: syncBrowserHistory,
          initialTabIndex: initialTabIndex.clamp(0, math.max(0, tabs.length - 1)),
          onClose: () {
            if (syncBrowserHistory && kIsWeb) {
              admin_url_sync.adminUrlSyncDriverClose();
            }
            Navigator.of(dialogContext).pop();
          },
        );

        return SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext ctx, BoxConstraints bc) {
              final double w = bc.maxWidth;
              final double h = bc.maxHeight;
              final bool wide = w >= 900;
              final double sheetWidth = math.min(560.0, w * (wide ? 0.42 : 1.0));
              if (wide) {
                return Align(
                  alignment: Alignment.centerRight,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(1, 0),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutCubic,
                    )),
                    child: Material(
                      elevation: 12,
                      color: Colors.white,
                      child: SizedBox(
                        width: sheetWidth,
                        height: h,
                        child: child,
                      ),
                    ),
                  ),
                );
              }
              return Align(
                alignment: Alignment.bottomCenter,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  )),
                  child: Material(
                    elevation: 16,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(20)),
                    color: Colors.white,
                    child: SizedBox(
                      width: w,
                      height: h * 0.92,
                      child: child,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  static int _presentSeq = 0;

  @override
  State<AdminEntityDrawer> createState() => _AdminEntityDrawerState();
}

class _AdminEntityDrawerState extends State<AdminEntityDrawer>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Map<String, Widget> _bodyCache = <String, Widget>{};
  final Map<String, Future<Widget>> _inFlight = <String, Future<Widget>>{};
  final Set<String> _loaded = <String>{};
  final List<String> _cacheOrder = <String>[];
  final Map<String, int> _tabResolvedAtMs = <String, int>{};
  final Map<String, int> _tabEpoch = <String, int>{};
  VoidCallback? _urlPopDispose;
  bool _openMsLogged = false;

  @override
  void initState() {
    super.initState();
    assert(widget.tabs.isNotEmpty, 'AdminEntityDrawer requires at least one tab');
    final int initialIndex =
        widget.initialTabIndex.clamp(0, widget.tabs.length - 1);
    _tabController = TabController(
      length: widget.tabs.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(_handleTabSelection);
    widget.controller?.attach(
      invalidateTabs: _invalidateTabs,
      close: () => (widget.onClose ?? () => Navigator.of(context).pop()).call(),
    );
    if (kIsWeb) {
      _urlPopDispose = admin_url_sync.adminUrlSyncListenPop(_onBrowserUriChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (!_openMsLogged && widget.debugOpenStartedMs != null) {
        _openMsLogged = true;
        final int elapsed =
            DateTime.now().millisecondsSinceEpoch - widget.debugOpenStartedMs!;
        debugPrint(
          '[AdminPerf][DRAWER_OPEN_MS] entity=${widget.entityType} id=${widget.entityId} seq=${widget.drawerSequence} ${elapsed}ms',
        );
      }
      _ensureTabLoaded(_tabController.index);
    });
  }

  void _onBrowserUriChanged(Uri uri) {
    if (!mounted) {
      return;
    }
    if (widget.entityType != 'driver') {
      return;
    }
    final AdminDriverDeepLink? link = AdminPortalRoutePaths.parseDriverDeepLinkUri(uri);
    if (link?.driverId != widget.entityId) {
      (widget.onClose ?? () => Navigator.of(context).pop()).call();
    }
  }

  void _invalidateTabs([Set<String>? tabIds]) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (tabIds == null) {
        for (final AdminEntityTabSpec t in widget.tabs) {
          _tabEpoch[t.id] = (_tabEpoch[t.id] ?? 0) + 1;
        }
        for (final String tabId in List<String>.from(_bodyCache.keys)) {
          _evictTab(tabId, reason: 'invalidate_all');
        }
        _bodyCache.clear();
        _loaded.clear();
        _inFlight.clear();
        _cacheOrder.clear();
        _tabResolvedAtMs.clear();
        return;
      }
      for (final String tabId in tabIds) {
        if (_bodyCache.containsKey(tabId) || _loaded.contains(tabId)) {
          _evictTab(tabId, reason: 'invalidate');
        }
        _bodyCache.remove(tabId);
        _loaded.remove(tabId);
        _inFlight.remove(tabId);
        _cacheOrder.remove(tabId);
        _tabResolvedAtMs.remove(tabId);
        _tabEpoch[tabId] = (_tabEpoch[tabId] ?? 0) + 1;
      }
    });
    if (_tabController.index >= 0 &&
        _tabController.index < widget.tabs.length) {
      _ensureTabLoaded(_tabController.index);
    }
  }

  void _evictTab(String tabId, {required String reason}) {
    debugPrint(
      '[AdminPerf][CACHE_EVICT] tab=$tabId entity=${widget.entityType} reason=$reason',
    );
  }

  void _handleTabSelection() {
    if (_tabController.indexIsChanging) {
      return;
    }
    if (kIsWeb &&
        widget.syncBrowserHistory &&
        widget.entityType == 'driver' &&
        _tabController.index >= 0 &&
        _tabController.index < widget.tabs.length) {
      admin_url_sync.adminUrlSyncReplaceDriverTab(
        widget.entityId,
        tab: widget.tabs[_tabController.index].id,
      );
    }
    _ensureTabLoaded(_tabController.index);
  }

  void _touchCacheOrder(String tabId) {
    _cacheOrder.remove(tabId);
    _cacheOrder.add(tabId);
    while (_cacheOrder.length > AdminEntityDrawer.maxCachedTabs) {
      final String victim = _cacheOrder.removeAt(0);
      if (victim == tabId) {
        continue;
      }
      _evictTab(victim, reason: 'lru');
      _bodyCache.remove(victim);
      _loaded.remove(victim);
      _tabResolvedAtMs.remove(victim);
      debugPrint(
        '[AdminPerf][DRAWER_CACHE] evict tab=$victim entity=${widget.entityType}',
      );
    }
  }

  bool _isTabStale(String tabId) {
    final Duration? ttl = widget.cachePolicy?.cacheTtlForTab(tabId) ??
        widget.tabStaleAfter?.call(tabId);
    if (ttl == null) {
      return false;
    }
    final int? at = _tabResolvedAtMs[tabId];
    if (at == null) {
      return false;
    }
    return DateTime.now().millisecondsSinceEpoch - at > ttl.inMilliseconds;
  }

  Future<void> _reloadTabFully(String tabId) async {
    debugPrint(
      '[AdminPerf][CACHE_EVICT] tab=$tabId entity=${widget.entityType} reason=pull_refresh',
    );
    final int idx =
        widget.tabs.indexWhere((AdminEntityTabSpec x) => x.id == tabId);
    if (idx < 0 || !mounted) {
      return;
    }
    setState(() {
      _loaded.remove(tabId);
      _bodyCache.remove(tabId);
      _inFlight.remove(tabId);
      _cacheOrder.remove(tabId);
      _tabResolvedAtMs.remove(tabId);
      _tabEpoch[tabId] = (_tabEpoch[tabId] ?? 0) + 1;
    });
    _ensureTabLoaded(idx);
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 55));
    while (mounted && DateTime.now().isBefore(deadline)) {
      if (_loaded.contains(tabId) && !_inFlight.containsKey(tabId)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  void _ensureTabLoaded(int index) {
    if (index < 0 || index >= widget.tabs.length) {
      return;
    }
    final String tabId = widget.tabs[index].id;
    if (_loaded.contains(tabId) && !_isTabStale(tabId)) {
      if (_inFlight.containsKey(tabId)) {
        return;
      }
      debugPrint(
        '[AdminPerf][CACHE_HIT] tab=$tabId entity=${widget.entityType} id=${widget.entityId}',
      );
      return;
    }
    if (_loaded.contains(tabId) && _isTabStale(tabId)) {
      debugPrint(
        '[AdminPerf][CACHE_MISS] tab=$tabId entity=${widget.entityType} reason=stale_ttl',
      );
      setState(() {
        _evictTab(tabId, reason: 'stale_ttl');
        _bodyCache.remove(tabId);
        _loaded.remove(tabId);
        _inFlight.remove(tabId);
        _cacheOrder.remove(tabId);
        _tabResolvedAtMs.remove(tabId);
        _tabEpoch[tabId] = (_tabEpoch[tabId] ?? 0) + 1;
      });
    }
    if (_inFlight.containsKey(tabId)) {
      return;
    }
    debugPrint(
      '[AdminPerf][CACHE_MISS] tab=$tabId entity=${widget.entityType} id=${widget.entityId}',
    );
    final int t0 = DateTime.now().millisecondsSinceEpoch;
    debugPrint('[AdminEntity] tab_load_start tab=$tabId entity=${widget.entityType}');
    final int epoch = (_tabEpoch[tabId] ?? 0) + 1;
    _tabEpoch[tabId] = epoch;
    final Future<Widget> future = widget.loadBody(tabId);
    _inFlight[tabId] = future;
    future.then((Widget body) {
      if (!mounted) {
        return;
      }
      if (_tabEpoch[tabId] != epoch) {
        debugPrint(
          '[AdminEntity] tab_load_stale_discard tab=$tabId epoch=$epoch current=${_tabEpoch[tabId]}',
        );
        return;
      }
      final int elapsed = DateTime.now().millisecondsSinceEpoch - t0;
      debugPrint(
        '[AdminPerf][TAB_LOAD_MS] tab=$tabId entity=${widget.entityType} id=${widget.entityId} ${elapsed}ms',
      );
      debugPrint(
        '[AdminEntity] tab_load_ok tab=$tabId entity=${widget.entityType} ${elapsed}ms',
      );
      setState(() {
        _bodyCache[tabId] = body;
        _loaded.add(tabId);
        _inFlight.remove(tabId);
        _tabResolvedAtMs[tabId] = DateTime.now().millisecondsSinceEpoch;
        _touchCacheOrder(tabId);
        debugPrint(
          '[AdminPerf][TAB_REBUILD] tab=$tabId entity=${widget.entityType}',
        );
        debugPrint(
          '[AdminPerf][REBUILD] tab=$tabId entity=${widget.entityType}',
        );
      });
    }).catchError((Object error, StackTrace stack) {
      if (!mounted) {
        return;
      }
      if (_tabEpoch[tabId] != epoch) {
        return;
      }
      debugPrint('[AdminEntity] tab_load_fail tab=$tabId error=$error');
      setState(() {
        _bodyCache[tabId] = _TabErrorPane(
          message: '$error',
          onRetry: () {
            unawaited(_reloadTabFully(tabId));
          },
        );
        _loaded.add(tabId);
        _inFlight.remove(tabId);
        _tabResolvedAtMs[tabId] = DateTime.now().millisecondsSinceEpoch;
        _touchCacheOrder(tabId);
        debugPrint(
          '[AdminPerf][TAB_REBUILD] tab=$tabId entity=${widget.entityType} (error)',
        );
        debugPrint(
          '[AdminPerf][REBUILD] tab=$tabId entity=${widget.entityType} (error)',
        );
      });
    });
    setState(() {});
  }

  @override
  void dispose() {
    _urlPopDispose?.call();
    _urlPopDispose = null;
    widget.controller?.detach();
    _tabController.removeListener(_handleTabSelection);
    _tabController.dispose();
    AdminEntityDrawer._openDrawerDepth =
        math.max(0, AdminEntityDrawer._openDrawerDepth - 1);
    debugPrint(
      '[AdminPerf][CACHE_SIZE] entity=${widget.entityType} id=${widget.entityId} '
      'cachedTabs=${_bodyCache.length} inFlight=${_inFlight.length}',
    );
    debugPrint(
      '[AdminPerf][MEMORY] entity=${widget.entityType} id=${widget.entityId} '
      'openDrawerDepth=${AdminEntityDrawer._openDrawerDepth} cachedTabs=${_bodyCache.length}',
    );
    debugPrint(
      '[AdminPerf][DRAWER_DISPOSE] entity=${widget.entityType} id=${widget.entityId} seq=${widget.drawerSequence} depth=${AdminEntityDrawer._openDrawerDepth}',
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AdminThemeTokens.ink,
                      ),
                    ),
                    if (widget.subtitle.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        widget.subtitle,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6F685E),
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      '${widget.entityType} · ${widget.entityId}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AdminThemeTokens.slate,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Material(
          color: const Color(0xFFF7F4EE),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: AdminThemeTokens.ink,
            unselectedLabelColor: AdminThemeTokens.slate,
            indicatorColor: AdminThemeTokens.gold,
            tabs: <Widget>[
              for (final AdminEntityTabSpec t in widget.tabs)
                Tab(
                  text: t.label,
                  icon: t.icon != null ? Icon(t.icon, size: 18) : null,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            physics: const NeverScrollableScrollPhysics(),
            children: <Widget>[
              for (final AdminEntityTabSpec t in widget.tabs)
                _TabPane(
                  tabId: t.id,
                  cache: _bodyCache,
                  inFlight: _inFlight,
                  onRefresh: _reloadTabFully,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabPane extends StatelessWidget {
  const _TabPane({
    required this.tabId,
    required this.cache,
    required this.inFlight,
    required this.onRefresh,
  });

  final String tabId;
  final Map<String, Widget> cache;
  final Map<String, Future<Widget>> inFlight;
  final Future<void> Function(String tabId) onRefresh;

  @override
  Widget build(BuildContext context) {
    if (cache.containsKey(tabId)) {
      return RefreshIndicator(
        onRefresh: () => onRefresh(tabId),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: cache[tabId]!,
        ),
      );
    }
    if (inFlight.containsKey(tabId)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              AdminEntityTabSkeleton(),
              SizedBox(height: 16),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Select this tab to load'),
      ),
    );
  }
}

class _TabErrorPane extends StatelessWidget {
  const _TabErrorPane({
    required this.message,
    this.onRetry,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SelectableText(
          message,
          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
        ),
        if (onRetry != null) ...<Widget>[
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ],
      ],
    );
  }
}
