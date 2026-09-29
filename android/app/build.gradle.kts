plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.liaoba"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.liaoba.im"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 极光推送占位符：JPush SDK AAR 的 meta-data（JPUSH_APPKEY/JPUSH_CHANNEL）
        // 需要 app 提供替换值；AppKey 需与 lib/main.dart 的 _jpushAppKey 保持一致，
        // 且包名 com.example.liaoba.im 需在极光后台登记
        manifestPlaceholders["JPUSH_PKGNAME"] = "com.example.liaoba.im"
        manifestPlaceholders["JPUSH_APPKEY"] = "d28a97237912f354ef3af622"
        manifestPlaceholders["JPUSH_CHANNEL"] = "flutter_channel"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
