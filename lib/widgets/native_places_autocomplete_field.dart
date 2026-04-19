import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/native_places_service.dart';

class NativePlacesAutocompleteField extends StatefulWidget {
  const NativePlacesAutocompleteField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onSelected,
    this.countryCode = 'NG',
    this.searchScopeLabel = 'Nigeria',
    this.queryTransform,
    this.fallbackSuggestionsBuilder,
  });

  final TextEditingController controller;
  final String hintText;
  final String countryCode;
  final String searchScopeLabel;
  final String Function(String query)? queryTransform;
  final List<NativePlaceSuggestion> Function(String query)?
  fallbackSuggestionsBuilder;
  final Future<void> Function(NativePlaceSuggestion suggestion) onSelected;

  @override
  State<NativePlacesAutocompleteField> createState() =>
      _NativePlacesAutocompleteFieldState();
}

class _NativePlacesAutocompleteFieldState
    extends State<NativePlacesAutocompleteField> {
  static const Color _gold = Color(0xFFB57A2A);
  static const Color _ink = Color(0xFF1E160D);
  static const Color _mutedInk = Color(0xFF74685B);
  static const Color _surface = Color(0xFFFFFBF5);
  static const Color _border = Color(0xFFE8D8BC);
  static const Color _danger = Color(0xFFD95842);

  final FocusNode _focusNode = FocusNode();
  final GlobalKey _fieldKey = GlobalKey();
  final LayerLink _fieldLayerLink = LayerLink();
  final Object _tapRegionGroupId = Object();
  final NativePlacesService _placesService = NativePlacesService.instance;

  Timer? _debounceTimer;
  OverlayEntry? _overlayEntry;
  List<NativePlaceSuggestion> _suggestions = const <NativePlaceSuggestion>[];
  bool _loading = false;
  bool _selectionInProgress = false;
  String? _errorText;
  String _lastSearchQuery = '';
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleTextChanged);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant NativePlacesAutocompleteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }

    oldWidget.controller.removeListener(_handleTextChanged);
    widget.controller.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    _removeOverlay();
    widget.controller.removeListener(_handleTextChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _handleFocusChanged() {
    _log(
      'focus changed hasFocus=${_focusNode.hasFocus} text="${widget.controller.text.trim()}"',
    );
    if (!_focusNode.hasFocus) {
      _clearSuggestions();
      return;
    }

    _scheduleSearch(widget.controller.text);
  }

  void _handleTextChanged() {
    if (_selectionInProgress) {
      return;
    }

    _scheduleSearch(widget.controller.text);
  }

  void _scheduleSearch(String value) {
    _debounceTimer?.cancel();
    final query = value.trim();
    _log(
      'schedule query="$query" hasFocus=${_focusNode.hasFocus} length=${query.length}',
    );
    if (!_focusNode.hasFocus || query.length < 2) {
      _clearSuggestions();
      return;
    }

    _debounceTimer = Timer(
      const Duration(milliseconds: 250),
      () => _performSearch(query),
    );
  }

  Future<void> _performSearch(String query) async {
    final requestId = ++_searchRequestId;
    _lastSearchQuery = query;
    final searchQuery = widget.queryTransform?.call(query).trim() ?? query;
    final fallbackSuggestions =
        widget.fallbackSuggestionsBuilder?.call(query) ??
        const <NativePlaceSuggestion>[];
    _log(
      'request fired id=$requestId query="$query" transformed="$searchQuery"',
    );
    setState(() {
      _loading = true;
      _errorText = null;
    });
    _markOverlayNeedsBuild(reason: 'loading_started');

    try {
      final suggestions = await _placesService.searchPlaces(
        query: searchQuery,
        countryCode: widget.countryCode,
      );
      if (!mounted || requestId != _searchRequestId) {
        return;
      }

      final resolvedSuggestions = suggestions.isNotEmpty
          ? suggestions
          : fallbackSuggestions;
      setState(() {
        _loading = false;
        _errorText = null;
        _suggestions = resolvedSuggestions;
      });
      _log(
        'request completed id=$requestId query="$query" predictions=${resolvedSuggestions.length}',
      );
      _markOverlayNeedsBuild(reason: 'results_ready');
    } on PlatformException catch (error) {
      if (!mounted || requestId != _searchRequestId) {
        return;
      }

      setState(() {
        _loading = false;
        _suggestions = fallbackSuggestions;
        _errorText = fallbackSuggestions.isEmpty
            ? _friendlyPlacesErrorText(error)
            : null;
      });
      _log(
        'request failed id=$requestId query="$query" error="${error.message ?? error.code}"',
      );
      _markOverlayNeedsBuild(reason: 'platform_error');
    } catch (_) {
      if (!mounted || requestId != _searchRequestId) {
        return;
      }

      setState(() {
        _loading = false;
        _suggestions = fallbackSuggestions;
        _errorText = fallbackSuggestions.isEmpty
            ? 'Search is having trouble right now. Please retry in a moment.'
            : null;
      });
      _log('request failed id=$requestId query="$query" error=unknown');
      _markOverlayNeedsBuild(reason: 'unknown_error');
    }
  }

  String _friendlyPlacesErrorText(PlatformException error) {
    final rawMessage = '${error.code} ${error.message ?? ''}'.toLowerCase();
    if (rawMessage.contains('native_places_plugin_unavailable') ||
        rawMessage.contains('missingpluginexception') ||
        rawMessage.contains('no implementation found')) {
      return 'Search engine did not initialize on iPhone yet. Close and reopen the app, then retry.';
    }
    if (rawMessage.contains('api key') ||
        rawMessage.contains('bundle') ||
        rawMessage.contains('places') ||
        rawMessage.contains('malformed')) {
      return 'Search is being configured on this device. Please retry in a moment.';
    }
    if (rawMessage.contains('network') || rawMessage.contains('connection')) {
      return 'We could not reach address search right now. Please retry.';
    }
    return 'We could not load address suggestions right now. Please retry.';
  }

  Future<void> _handleSuggestionTap(NativePlaceSuggestion suggestion) async {
    _log(
      'tap fired placeId=${suggestion.placeId} fullText="${suggestion.fullText}"',
    );
    _selectionInProgress = true;
    _debounceTimer?.cancel();
    _searchRequestId += 1;

    setState(() {
      _loading = false;
      _errorText = null;
      _suggestions = const <NativePlaceSuggestion>[];
    });
    _markOverlayNeedsBuild(reason: 'selection_started');

    widget.controller
      ..text = suggestion.fullText
      ..selection = TextSelection.collapsed(offset: suggestion.fullText.length);

    try {
      await widget.onSelected(suggestion);
    } finally {
      _selectionInProgress = false;
      if (mounted) {
        _focusNode.unfocus();
      }
    }
  }

  void _clearSuggestions() {
    _debounceTimer?.cancel();
    _searchRequestId += 1;
    if (_suggestions.isEmpty && !_loading && _errorText == null) {
      _markOverlayNeedsBuild(reason: 'clear_noop');
      return;
    }

    setState(() {
      _loading = false;
      _suggestions = const <NativePlaceSuggestion>[];
      _errorText = null;
    });
    _log('cleared suggestions');
    _markOverlayNeedsBuild(reason: 'cleared');
  }

  bool get _showDropdown =>
      _focusNode.hasFocus &&
      (_loading || _errorText != null || _suggestions.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncOverlay();
      }
    });

    _log(
      'widget rebuilt showDropdown=$_showDropdown loading=$_loading suggestions=${_suggestions.length} error=${_errorText != null}',
    );

    return TapRegion(
      groupId: _tapRegionGroupId,
      onTapOutside: (_) => _focusNode.unfocus(),
      child: CompositedTransformTarget(
        link: _fieldLayerLink,
        child: TextField(
          key: _fieldKey,
          controller: widget.controller,
          focusNode: _focusNode,
          textInputAction: TextInputAction.search,
          style: const TextStyle(
            color: _ink,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            hintText: widget.hintText,
            filled: true,
            fillColor: _surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 18,
            ),
            hintStyle: const TextStyle(
              color: _mutedInk,
              fontWeight: FontWeight.w500,
            ),
            prefixIcon: const Icon(
              Icons.location_on_outlined,
              color: _gold,
              size: 20,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 48,
              minHeight: 20,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(color: _border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide(color: _border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: const BorderSide(color: _gold, width: 1.4),
            ),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(_gold),
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  void _syncOverlay() {
    if (_showDropdown) {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) {
        _log('overlay unavailable');
        return;
      }

      if (_overlayEntry == null) {
        _overlayEntry = _buildOverlayEntry();
        overlay.insert(_overlayEntry!);
        _log('overlay inserted');
      } else {
        _overlayEntry!.markNeedsBuild();
      }
      return;
    }

    _removeOverlay();
  }

  void _removeOverlay() {
    final overlayEntry = _overlayEntry;
    if (overlayEntry == null) {
      return;
    }

    overlayEntry.remove();
    _overlayEntry = null;
    _log('overlay removed');
  }

  void _markOverlayNeedsBuild({required String reason}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _log(
        'overlay sync reason=$reason showDropdown=$_showDropdown suggestions=${_suggestions.length}',
      );
      _syncOverlay();
    });
  }

  OverlayEntry _buildOverlayEntry() {
    return OverlayEntry(
      builder: (context) {
        final renderBox =
            _fieldKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) {
          return const SizedBox.shrink();
        }

        return Positioned.fill(
          child: IgnorePointer(
            ignoring: false,
            child: CompositedTransformFollower(
              link: _fieldLayerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 8),
              child: TapRegion(
                groupId: _tapRegionGroupId,
                child: Material(
                  elevation: 10,
                  color: _surface,
                  borderRadius: BorderRadius.circular(22),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: renderBox.size.width,
                      maxWidth: renderBox.size.width,
                      maxHeight: 240,
                    ),
                    child: _buildDropdownBody(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _log(String message) {
    debugPrint('[RiderSearchField:${widget.hintText}] $message');
  }

  Widget _buildDropdownBody() {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(_gold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Finding places in ${widget.searchScopeLabel}...',
                style: const TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (_errorText != null) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: _buildStateCard(
          icon: Icons.cloud_off_outlined,
          title: 'Search is reconnecting',
          message: _errorText!,
          actionLabel: _lastSearchQuery.isEmpty ? null : 'Retry',
          onAction: _lastSearchQuery.isEmpty
              ? null
              : () {
                  unawaited(_performSearch(_lastSearchQuery));
                },
        ),
      );
    }

    if (_suggestions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: _buildStateCard(
          icon: Icons.travel_explore_outlined,
          title: 'Try a street or landmark',
          message:
              'Search for a district, estate, street, or landmark in ${widget.searchScopeLabel}.',
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: _suggestions.length,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: _border.withValues(alpha: 0.8)),
      itemBuilder: (context, index) {
        final suggestion = _suggestions[index];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.location_on_outlined,
              color: _gold,
              size: 18,
            ),
          ),
          title: Text(
            suggestion.primaryText.isNotEmpty
                ? suggestion.primaryText
                : suggestion.fullText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _ink, fontWeight: FontWeight.w700),
          ),
          subtitle: suggestion.secondaryText.isEmpty
              ? null
              : Text(
                  suggestion.secondaryText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _mutedInk,
                    fontWeight: FontWeight.w500,
                  ),
                ),
          onTap: () => _handleSuggestionTap(suggestion),
        );
      },
    );
  }

  Widget _buildStateCard({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: actionLabel == null
            ? _gold.withValues(alpha: 0.06)
            : _danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: actionLabel == null
              ? _gold.withValues(alpha: 0.12)
              : _danger.withValues(alpha: 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: actionLabel == null ? _gold : _danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(
              color: _mutedInk,
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: _ink,
                padding: EdgeInsets.zero,
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
