package com.example.nexride_driver

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureHighImportanceNotificationChannel(applicationContext)
    }

    companion object {
        private const val HIGH_IMPORTANCE_CHANNEL_ID = "nexride_high_importance"

        /**
         * Registers the FCM default channel with `IMPORTANCE_HIGH` so ride
         * offers, calls and chat alerts head-up, vibrate, and play sound on
         * Android 8+. Without this, Android auto-creates the channel at
         * default importance and FCM `priority: high` payloads silently
         * degrade to banners.
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
                "Ride offers, calls and chat",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Ride offers, voice calls and chat messages."
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
