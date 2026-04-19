package com.nexride.rider

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import com.google.android.libraries.places.api.Places
import com.google.android.libraries.places.api.model.AutocompleteSessionToken
import com.google.android.libraries.places.api.model.Place
import com.google.android.libraries.places.api.net.FetchPlaceRequest
import com.google.android.libraries.places.api.net.FindAutocompletePredictionsRequest
import com.google.android.libraries.places.api.net.PlacesClient
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NativePlacesPlugin private constructor(
    private val context: Context,
    private val placesClient: PlacesClient,
) : MethodChannel.MethodCallHandler {

    private var sessionToken: AutocompleteSessionToken? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "searchPlaces" -> searchPlaces(call, result)
            "fetchPlaceDetails" -> fetchPlaceDetails(call, result)
            else -> result.notImplemented()
        }
    }

    private fun searchPlaces(call: MethodCall, result: MethodChannel.Result) {
        val query = call.argument<String>("query")?.trim().orEmpty()
        Log.d(TAG, "searchPlaces query=$query")
        if (query.length < 2) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }

        val countryCode = call.argument<String>("countryCode")?.trim()?.uppercase().orEmpty()
        val currentToken = sessionToken ?: AutocompleteSessionToken.newInstance().also {
            sessionToken = it
        }

        val requestBuilder = FindAutocompletePredictionsRequest.builder()
            .setSessionToken(currentToken)
            .setQuery(query)

        if (countryCode.isNotEmpty()) {
            requestBuilder.setCountries(countryCode)
        }

        placesClient.findAutocompletePredictions(requestBuilder.build())
            .addOnSuccessListener { response ->
                val payload = response.autocompletePredictions.map { prediction ->
                    mapOf(
                        "placeId" to prediction.placeId,
                        "primaryText" to prediction.getPrimaryText(null).toString(),
                        "secondaryText" to prediction.getSecondaryText(null).toString(),
                        "fullText" to prediction.getFullText(null).toString(),
                    )
                }
                Log.d(
                    TAG,
                    "searchPlaces success query=$query predictions=${payload.size}",
                )
                result.success(payload)
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "searchPlaces failed", error)
                result.error(
                    "places_search_failed",
                    error.localizedMessage ?: "Unable to load place suggestions.",
                    null,
                )
            }
    }

    private fun fetchPlaceDetails(call: MethodCall, result: MethodChannel.Result) {
        val placeId = call.argument<String>("placeId")?.trim().orEmpty()
        Log.d(TAG, "fetchPlaceDetails placeId=$placeId")
        if (placeId.isEmpty()) {
            result.success(null)
            return
        }

        val request = FetchPlaceRequest.builder(
            placeId,
            listOf(
                Place.Field.ID,
                Place.Field.NAME,
                Place.Field.ADDRESS,
                Place.Field.LAT_LNG,
            ),
        ).setSessionToken(sessionToken).build()

        placesClient.fetchPlace(request)
            .addOnSuccessListener { response ->
                val place = response.place
                val location = place.latLng
                if (location == null) {
                    result.success(null)
                    return@addOnSuccessListener
                }

                result.success(
                    mapOf(
                        "placeId" to (place.id ?: placeId),
                        "address" to (place.address ?: place.name ?: ""),
                        "latitude" to location.latitude,
                        "longitude" to location.longitude,
                    ),
                )
                Log.d(
                    TAG,
                    "fetchPlaceDetails success placeId=${place.id ?: placeId} lat=${location.latitude} lng=${location.longitude}",
                )
                sessionToken = null
            }
            .addOnFailureListener { error ->
                Log.e(TAG, "fetchPlaceDetails failed", error)
                result.error(
                    "place_details_failed",
                    error.localizedMessage ?: "Unable to load place details.",
                    null,
                )
                sessionToken = null
            }
    }

    companion object {
        private const val CHANNEL = "nexride/places"
        private const val TAG = "NativePlacesPlugin"

        fun registerWith(flutterEngine: FlutterEngine, context: Context) {
            val apiKey = googleMapsApiKey(context)
            Log.d(
                TAG,
                "maps metadata check package=${context.packageName} apiKeyPresent=${apiKey.isNotEmpty()}",
            )
            if (apiKey.isEmpty()) {
                Log.w(TAG, "Google Maps API key missing from AndroidManifest.xml")
                return
            }

            if (!Places.isInitialized()) {
                Places.initialize(context, apiKey)
                Log.d(TAG, "Places SDK initialized for package ${context.packageName}")
            } else {
                Log.d(TAG, "Places SDK already initialized for package ${context.packageName}")
            }

            if (context.packageName.startsWith("com.example.")) {
                Log.w(
                    TAG,
                    "Package ${context.packageName} is still using an example applicationId. " +
                        "Ensure this exact package name and SHA-1 are allowed on the Google Maps Platform key.",
                )
            }

            val channel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                CHANNEL,
            )
            channel.setMethodCallHandler(
                NativePlacesPlugin(
                    context = context,
                    placesClient = Places.createClient(context),
                ),
            )
        }

        private fun googleMapsApiKey(context: Context): String {
            return try {
                val appInfo = context.packageManager.getApplicationInfo(
                    context.packageName,
                    PackageManager.GET_META_DATA,
                )
                appInfo.metaData
                    ?.getString("com.google.android.geo.API_KEY")
                    ?.trim()
                    .orEmpty()
            } catch (error: Exception) {
                Log.e(TAG, "Unable to resolve Google Maps API key from manifest", error)
                ""
            }
        }
    }
}
