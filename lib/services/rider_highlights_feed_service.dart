import 'package:http/http.dart' as http;

/// One slide in the rider “Choose a service” highlights carousel.
class RiderHighlightSlide {
  RiderHighlightSlide({
    required this.id,
    required this.badgeLabel,
    required this.title,
    required this.subtitle,
    this.link,
    required this.iconKey,
  });

  final String id;
  final String badgeLabel;
  final String title;
  final String subtitle;
  final Uri? link;

  /// `news` | `music` for icon choice in UI.
  final String iconKey;
}

/// Fetches CNN (RSS) and Billboard (RSS) headlines for a lightweight in-app carousel.
/// Falls back to curated static cards if the network or feeds fail.
class RiderHighlightsFeedService {
  const RiderHighlightsFeedService();

  static const String _userAgent = 'NexRideRider/1.0 (highlights carousel)';

  static const Duration _timeout = Duration(seconds: 12);

  static List<RiderHighlightSlide> staticFallback() {
    return <RiderHighlightSlide>[
      RiderHighlightSlide(
        id: 'static_cnn',
        badgeLabel: 'News',
        title: 'CNN — world headlines',
        subtitle: 'Open the latest stories in your browser.',
        link: Uri.parse('https://www.cnn.com/world'),
        iconKey: 'news',
      ),
      RiderHighlightSlide(
        id: 'static_music_1',
        badgeLabel: 'Music',
        title: 'New music Friday',
        subtitle: 'Catch releases and chart moves on Billboard.',
        link: Uri.parse('https://www.billboard.com/music/'),
        iconKey: 'music',
      ),
      RiderHighlightSlide(
        id: 'static_music_2',
        badgeLabel: 'Music',
        title: 'Playlists & tours',
        subtitle: 'Discover what is trending before your ride.',
        link: Uri.parse('https://www.billboard.com/charts/'),
        iconKey: 'music',
      ),
    ];
  }

  Future<List<RiderHighlightSlide>> fetchSlides({
    int maxNews = 5,
    int maxMusic = 4,
  }) async {
    final slides = <RiderHighlightSlide>[];

    try {
      final cnnBody = await _getBody(
        Uri.parse('https://rss.cnn.com/rss/edition.rss'),
      );
      slides.addAll(
        _parseRssItems(
          cnnBody,
          badgeLabel: 'CNN',
          iconKey: 'news',
          maxItems: maxNews,
          idPrefix: 'cnn',
        ),
      );
    } catch (_) {
      /* feed optional */
    }

    try {
      final bbBody = await _getBody(
        Uri.parse('https://www.billboard.com/feed/'),
      );
      slides.addAll(
        _parseRssItems(
          bbBody,
          badgeLabel: 'Billboard',
          iconKey: 'music',
          maxItems: maxMusic,
          idPrefix: 'bb',
        ),
      );
    } catch (_) {
      /* feed optional */
    }

    if (slides.isEmpty) {
      return staticFallback();
    }

    return slides;
  }

  Future<String> _getBody(Uri uri) async {
    final response = await http
        .get(
          uri,
          headers: <String, String>{'User-Agent': _userAgent},
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('http_${response.statusCode}');
    }
    return response.body;
  }

  List<RiderHighlightSlide> _parseRssItems(
    String xml, {
    required String badgeLabel,
    required String iconKey,
    required int maxItems,
    required String idPrefix,
  }) {
    final out = <RiderHighlightSlide>[];
    final itemRe = RegExp(r'<item\b[^>]*>([\s\S]*?)</item>', caseSensitive: false);
    var index = 0;
    for (final match in itemRe.allMatches(xml)) {
      if (out.length >= maxItems) break;
      final block = match.group(1) ?? '';
      final title = _firstTag(block, 'title');
      if (title == null || title.isEmpty) continue;
      final link = _firstLink(block);
      final pub = _firstTag(block, 'pubDate') ?? '';
      final subtitle = pub.isNotEmpty ? pub : 'Tap to read the full story';
      final id = '${idPrefix}_${index}_${_hash(title)}';
      index++;
      out.add(
        RiderHighlightSlide(
          id: id,
          badgeLabel: badgeLabel,
          title: _stripTags(_decodeXmlEntities(title)).trim(),
          subtitle: _decodeXmlEntities(subtitle).trim(),
          link: link,
          iconKey: iconKey,
        ),
      );
    }
    return out;
  }

  String? _firstTag(String block, String tag) {
    final cdata = RegExp(
      '<$tag><!\\[CDATA\\[([\\s\\S]*?)\\]\\]></$tag>',
      caseSensitive: false,
    ).firstMatch(block);
    if (cdata != null && (cdata.group(1)?.trim().isNotEmpty ?? false)) {
      return cdata.group(1);
    }
    final plain = RegExp(
      '<$tag>([\\s\\S]*?)</$tag>',
      caseSensitive: false,
    ).firstMatch(block);
    return plain?.group(1)?.trim();
  }

  Uri? _firstLink(String block) {
    final guid = _firstTag(block, 'guid');
    if (guid != null && guid.startsWith('http')) {
      return Uri.tryParse(guid.trim());
    }
    final link = _firstTag(block, 'link');
    if (link != null && link.startsWith('http')) {
      return Uri.tryParse(link.trim());
    }
    return null;
  }

  String _decodeXmlEntities(String raw) {
    return raw
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (m) {
            final n = int.tryParse(m.group(1) ?? '');
            if (n == null) return m.group(0) ?? '';
            return String.fromCharCode(n);
          },
        );
  }

  String _stripTags(String s) {
    return s.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  int _hash(String s) {
    var h = 0;
    for (final code in s.codeUnits) {
      h = (h * 31 + code) & 0x7fffffff;
    }
    return h;
  }
}
