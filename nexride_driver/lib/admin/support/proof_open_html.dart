// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Future<void> adminOpenProofInBrowser(String url) async {
  html.window.open(url.trim(), '_blank', 'noopener,noreferrer');
}
