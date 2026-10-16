import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyFile = rootProject.file("key.properties")
val releaseKeys = Properties().apply {
    if (releaseKeyFile.isFile) releaseKeyFile.inputStream().use { load(it) }
}

android {
    namespace = "org.mewx.wenku8_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    // The separately authorized API runtime must remain byte-for-byte intact.
    // AGP otherwise strips its symbols even when jniLibs contains original files.
    packaging.jniLibs.keepDebugSymbols.add("**/libcpp.so")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.mewx.wenku8_flutter"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "org.mewx.wenku8_flutter.SessionFixtureInstrumentation"
    }

    if (releaseKeyFile.isFile) {
        signingConfigs.create("distribution") {
            keyAlias = releaseKeys.getProperty("keyAlias")
            keyPassword = releaseKeys.getProperty("keyPassword")
            storeFile = rootProject.file(requireNotNull(releaseKeys.getProperty("storeFile")))
            storePassword = releaseKeys.getProperty("storePassword")
        }
    }

    buildTypes {
        getByName("debug") {
            // The integration runner uninstalls its package on completion.
            // Keep rendering probes separate from the user's release data.
            applicationIdSuffix = ".render_probe"
        }
        getByName("profile") {
            applicationIdSuffix = ".profile_probe"
        }
        release {
            // Local previews remain install-compatible. Public distributions
            // use an owner's untracked key.properties, never an embedded key.
            signingConfig = signingConfigs.getByName(
                if (releaseKeyFile.isFile) "distribution" else "debug"
            )
        }
    }

    // Match the embedded API library to the Flutter code actually compiled for
    // this APK. Otherwise a one-ABI build advertises extra, unusable ABIs solely
    // because libcpp.so exists for them. Let Flutter own split-APK filtering.
    val targets = project.findProperty("target-platform")?.toString()
    if (targets != null && project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {
        val targetAbis = targets.split(",").map { platform ->
            when (platform) {
                "android-arm" -> "armeabi-v7a"
                "android-arm64" -> "arm64-v8a"
                "android-x64" -> "x86_64"
                else -> error("Unsupported Flutter target platform: $platform")
            }
        }
        buildTypes.configureEach {
            ndk.abiFilters.clear()
            ndk.abiFilters.addAll(targetAbis)
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Keep the media host classes available to the app's shared-engine wiring.
    implementation("androidx.media:media:1.7.0")
    testImplementation("junit:junit:4.13.2")
}
