# Flutter — keep engine and plugin classes when R8 minify is enabled.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Play Core — optional refs from Flutter embedding (deferred components).
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# Firebase Cloud Messaging
-keep class com.google.firebase.messaging.** { *; }
-keep class com.google.firebase.iid.** { *; }
-keep class io.flutter.plugins.firebase.messaging.** { *; }
-keepclassmembers class * {
  @com.google.firebase.messaging.RemoteMessage *;
}

# flutter_local_notifications (if added later)
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class androidx.core.app.NotificationCompat** { *; }
-keep class android.app.Notification** { *; }
-keepnames class * extends android.app.Service
-keepnames class * extends android.content.BroadcastReceiver

# Gson / JSON reflection (plugins)
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
-dontwarn sun.misc.**
-keep class com.google.gson.** { *; }
