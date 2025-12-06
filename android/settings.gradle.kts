// android/settings.gradle.kts (Kotlin DSL)

import java.util.Properties

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        // Flutter’s Maven (added by Flutter tool)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS) // allow subprojects to add repos if needed
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

// --- Read flutter.sdk from local.properties ---
val properties = Properties().apply {
    val f = file("local.properties")
    check(f.exists()) {
        "Missing local.properties. Flutter sets this up. Run `flutter pub get` at the project root."
    }
    f.inputStream().use { load(it) }
}

val flutterSdkPath = properties.getProperty("flutter.sdk")
    ?: error("`flutter.sdk` not found in local.properties")

// Include Flutter’s Gradle build logic
includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

// Your app module
include(":app")

