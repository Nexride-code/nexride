plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Apply Firebase google-services plugin only when google-services.json is present.
// Until the file is added (download from Firebase console for the
// `com.example.nexride_driver` Android app), Firebase still works through
// `firebase_options.dart`, but FCM push delivery is more reliable once the
// gradle plugin embeds google_app_id into resources at build time.
val googleServicesJson = file("google-services.json")
if (googleServicesJson.exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Optional production signing: copy `key.properties.template` to
// `android/key.properties`, fill in keystore credentials, then release builds
// will sign with the production keystore. If `key.properties` is missing the
// release build falls back to the debug keystore (so `flutter run --release`
// still works locally).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = java.util.Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(java.io.FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.nexride_driver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // NOTE: Application ID is intentionally legacy `com.example.nexride_driver`
        // because the Firebase Android app (`1:684231437366:android:ce00fc6559282fbaec3c97`)
        // and Play Store listing are registered under it. Renaming requires
        // (a) registering a new Firebase Android app, (b) re-uploading the AAB
        // with a new package name, (c) updating signing keystore. Do NOT change
        // without coordinating Firebase + Play Store migration.
        applicationId = "com.example.nexride_driver"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // Use production keystore when key.properties is configured;
            // otherwise fall back to debug for local `flutter run --release`.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Disable R8 shrinking: Agora, Google Maps, geolocator, and audioplayers
            // use reflection and JNI; R8 removes needed classes and causes native crashes.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
