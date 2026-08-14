import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is read from `android/key.properties` (git-ignored) so the
// keystore password and key alias never live in source control. See
// `key.properties.example` and SETUP_FIREBASE.md for how to generate it.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "com.geonixsoftware.wrench"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.geonixsoftware.wrench"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Only populated when key.properties exists; release builds require it.
            if (keystorePropertiesFile.exists()) {
                // checkNotNull fails fast (instead of a cryptic NPE) if a key is
                // present but blank.
                storeFile = file(checkNotNull(keystoreProperties["storeFile"]) as String)
                storePassword = checkNotNull(keystoreProperties["storePassword"]) as String
                keyAlias = checkNotNull(keystoreProperties["keyAlias"]) as String
                keyPassword = checkNotNull(keystoreProperties["keyPassword"]) as String
            }
        }
    }

    buildTypes {
        release {
            // SECURITY: never silently fall back to the debug keystore for a
            // release build — the debug key is publicly known. If key.properties
            // is absent, fail the build loudly so a production artifact is never
            // signed with the wrong key.
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "Release builds require android/key.properties with a real " +
                        "keystore. Copy android/key.properties.example and fill it in.",
                )
            }
            signingConfig = signingConfigs.getByName("release")
            // Shrink and obfuscate the release binary.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
