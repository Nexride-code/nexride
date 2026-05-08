import 'package:url_launcher/url_launcher.dart';

Future<void> adminOpenProofInBrowser(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) {
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
