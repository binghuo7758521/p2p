plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.p2p.p2p_android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.p2p.p2p_android"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // v5.8 体积优化：仅打包 arm64-v8a（覆盖 2016+ 主流真机），
        // 原生库由 3 份降为 1 份，APK 约 102MB → 40MB。
        // 代价：32 位老设备与 x86_64 模拟器无法安装。
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        // 兜底过滤：AAR 依赖（WebRTC/ML Kit）的 so 不受 abiFilters 控制时，
        // 在打包阶段排除非 arm64 架构，确保产物仅含 arm64-v8a
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/*.so",
                "lib/x86_64/*.so",
                "lib/x86/*.so",
            )
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
