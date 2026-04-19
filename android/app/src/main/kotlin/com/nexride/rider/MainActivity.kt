package com.nexride.rider

import android.content.pm.PackageManager
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
    }
}
