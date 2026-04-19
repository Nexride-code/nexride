import 'package:flutter_test/flutter_test.dart';
import 'package:nexride_driver/firebase_options.dart';

void main() {
  test('web Firebase options use the real web app config', () {
    expect(DefaultFirebaseOptions.webAppIdLooksLikeMobileConfig, isFalse);
    expect(DefaultFirebaseOptions.web.appId, contains(':web:'));
    expect(
        DefaultFirebaseOptions.web.authDomain, 'nexride-8d5bc.firebaseapp.com');
    expect(
      DefaultFirebaseOptions.web.databaseURL,
      'https://nexride-8d5bc-default-rtdb.firebaseio.com',
    );
  });
}
