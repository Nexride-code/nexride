// Web + same NexRide production project as public/track.html
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    throw UnsupportedError('nexride_website is web-only');
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCy3eR2_3xjz25kWIdxyYcc514VMjhp5NQ',
    appId: '1:684231437366:web:6e1b737dee1c5457ec3c97',
    messagingSenderId: '684231437366',
    projectId: 'nexride-8d5bc',
    authDomain: 'nexride-8d5bc.firebaseapp.com',
    databaseURL: 'https://nexride-8d5bc-default-rtdb.firebaseio.com',
    storageBucket: 'nexride-8d5bc.firebasestorage.app',
    measurementId: 'G-5S1Y9JNRPG',
  );
}
