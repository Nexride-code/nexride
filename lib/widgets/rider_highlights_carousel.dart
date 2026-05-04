import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/rider_highlights_feed_service.dart';

/// Slideable “ads” row under **Choose a service**: CNN + music headlines from RSS.
class RiderHighlightsCarousel extends StatefulWidget {
  const RiderHighlightsCarousel({
    super.key,
    this.accentColor = const Color(0xFFB57A2A),
  });

  final Color accentColor;

  @override
  State<RiderHighlightsCarousel> createState() => _RiderHighlightsCarouselState();
}

class _RiderHighlightsCarouselState extends State<RiderHighlightsCarousel> {
  final PageController _pageController = PageController(viewportFraction: 0.88);
  final RiderHighlightsFeedService _feed = const RiderHighlightsFeedService();

  List<RiderHighlightSlide> _slides = RiderHighlightsFeedService.staticFallback();
  bool _loading = true;
  int _pageIndex = 0;
  Timer? _autoAdvance;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final fetched = await _feed.fetchSlides();
      if (!mounted) return;
      setState(() {
        _slides = fetched;
        _loading = false;
      });
      _restartAutoAdvance();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _slides = RiderHighlightsFeedService.staticFallback();
        _loading = false;
      });
      _restartAutoAdvance();
    }
  }

  void _restartAutoAdvance() {
    _autoAdvance?.cancel();
    if (_slides.length <= 1) return;
    _autoAdvance = Timer.periodic(const Duration(seconds: 9), (_) {
      if (!mounted || !_pageController.hasClients) return;
      final next = (_pageIndex + 1) % _slides.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _autoAdvance?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _openLink(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not open this link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accentColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.newspaper_rounded, size: 18, color: accent.withValues(alpha: 0.95)),
            const SizedBox(width: 8),
            Text(
              'Updates while you choose',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const Spacer(),
            if (_loading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: accent.withValues(alpha: 0.9),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 118,
          child: PageView.builder(
            controller: _pageController,
            itemCount: _slides.length,
            padEnds: false,
            onPageChanged: (int i) => setState(() => _pageIndex = i),
            itemBuilder: (BuildContext context, int index) {
              final slide = _slides[index];
              final isMusic = slide.iconKey == 'music';
              return Padding(
                padding: EdgeInsets.only(right: index < _slides.length - 1 ? 10 : 0),
                child: Material(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: slide.link != null ? () => unawaited(_openLink(slide.link!)) : null,
                    child: Ink(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isMusic
                              ? accent.withValues(alpha: 0.35)
                              : Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              isMusic ? Icons.library_music_rounded : Icons.public_rounded,
                              color: accent,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    slide.badgeLabel,
                                    style: TextStyle(
                                      color: accent.withValues(alpha: 0.98),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  slide.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    height: 1.22,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  slide.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.52),
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (slide.link != null)
                            Icon(
                              Icons.open_in_new_rounded,
                              size: 18,
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_slides.length > 1) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List<Widget>.generate(_slides.length, (int i) {
              final active = i == _pageIndex;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: active ? accent : Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }
}
