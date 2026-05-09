import 'package:flutter/foundation.dart';

import 'web_title_stub.dart'
    if (dart.library.html) 'web_title_web.dart' as impl;

void setWebTitle(String title) {
  if (kIsWeb) {
    impl.setDocumentTitle(title);
  }
}
