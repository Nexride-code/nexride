package com.nexride.rider

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val apiKeyPresent = try {
            val appInfo = packageManager.getApplicationInfo(
                packageName,
                PackageManager.GET_META_DATA,
            )
            !appInfo.metaData
                ?.getString("com.google.android.geo.API_KEY")
                ?.trim()
                .isNullOrEmpty()
        } catch (_: Exception) {
            false
        }

        Log.d(
            TAG,
            "Activity created package=$packageName mapsManifestKeyPresent=$apiKeyPresent",
        )

        ensureHighImportanceNotificationChannel(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NativePlacesPlugin.registerWith(
            flutterEngine = flutterEngine,
            context = applicationContext,
        )
    }

    companion object {
        private const val TAG = "RiderMapsMainActivity"
        private const val HIGH_IMPORTANCE_CHANNEL_ID = "nexride_high_importance"

        /**
         * Registers the FCM default channel with `IMPORTANCE_HIGH` so push
         * notifications head-up, vibrate, and play sound on Android 8+. Without
         * this, the OS auto-creates the channel at default importance and
         * subsequent FCM `priority: high` payloads silently degrade to banners.
         */
        fun ensureHighImportanceNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                return
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager ?: return
            val existing = manager.getNotificationChannel(HIGH_IMPORTANCE_CHANNEL_ID)
            if (existing != null && existing.importance >= NotificationManager.IMPORTANCE_HIGH) {
                return
            }
            val channel = NotificationChannel(
                HIGH_IMPORTANCE_CHANNEL_ID,
                "Trips, calls and chat",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Ride updates, voice calls and chat messages."
                enableVibration(true)
                enableLights(true)
                setShowBadge(true)
                setBypassDnd(false)
                lockscreenVisibility = NotificationManager.IMPORTANCE_HIGH
                val attrs = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build()
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                    attrs,
                )
            }
            manager.createNotificationChannel(channel)
        }
    }
}
