# Flutter — keep engine and plugin classes when R8 minify is enabled.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Play Core — optional refs from Flutter embedding (deferred components); keep splits install API.
-dontwarn com.google.android.play.core.**
