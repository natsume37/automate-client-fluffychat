import java.util.Properties
import java.io.FileInputStream
import java.util.Base64

// 从 dart-define 读取环境变量
fun getDartDefine(key: String): String? {
    val dartDefines = project.findProperty("dart-defines")?.toString() ?: return null
    return dartDefines.split(",")
        .mapNotNull { encoded ->
            try {
                String(Base64.getDecoder().decode(encoded))
            } catch (e: Exception) {
                null
            }
        }
        .find { it.startsWith("$key=") }
        ?.substringAfter("=")
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

repositories {
    flatDir {
        dirs("libs")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") // For flutter_local_notifications // Workaround for: https://github.com/MaikuB/flutter_local_notifications/issues/2286
    implementation("androidx.core:core-ktx:1.17.0") // For Android Auto

    // 阿里云一键登录 SDK (官方)
    implementation(files("libs/auth_number_product-2.14.14-log-online-standard-cuum-release.aar"))
    implementation(files("libs/logger-2.2.2-release.aar"))
    implementation(files("libs/main-2.2.3-release.aar"))

    // 阿里云推送厂商通道 SDK
    implementation("com.aliyun.ams:alicloud-android-third-push:3.9.1")
    implementation("com.aliyun.ams:alicloud-android-third-push-xiaomi:3.9.0")
    implementation("com.aliyun.ams:alicloud-android-third-push-vivo:3.9.0")
    implementation("com.aliyun.ams:alicloud-android-third-push-honor:3.9.0")
    implementation("com.aliyun.ams:alicloud-android-third-push-oppo:3.9.0")
}


// Workaround for https://pub.dev/packages/unifiedpush#the-build-fails-because-of-duplicate-classes
configurations.all {
    // Use the latest version published: https://central.sonatype.com/artifact/com.google.crypto.tink/tink-android
    val tink = "com.google.crypto.tink:tink-android:1.17.0"
    // You can also use the library declaration catalog
    // val tink = libs.google.tink
    resolutionStrategy {
        force(tink)
        dependencySubstitution {
            substitute(module("com.google.crypto.tink:tink")).using(module(tink))
        }
    }
}


android {
    namespace = "com.creativekoalas.psygo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    val hasReleaseKeystore = keystorePropertiesFile.exists()
    if (hasReleaseKeystore) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    } else {
        println("Local test build: android/key.properties not found, falling back to debug signing.")
    }

    // 从 dart-define 读取包名后缀（prod 为空，test 为 _test，dev 为 _dev）
    val appIdSuffix = getDartDefine("APP_ID_SUFFIX") ?: ""
    // 从 dart-define 读取 app 名称
    val appName = getDartDefine("APP_NAME") ?: "PsyGo"
    val vivoAppId = getDartDefine("VIVO_APP_ID") ?: ""
    val vivoApiKey = getDartDefine("VIVO_API_KEY") ?: ""
    val xiaomiAppId = getDartDefine("XIAOMI_APP_ID") ?: ""
    val xiaomiAppKey = getDartDefine("XIAOMI_APP_KEY") ?: ""
    val honorAppId = getDartDefine("HONOR_APP_ID") ?: ""
    val oppoAppKey = getDartDefine("OPPO_APP_KEY") ?: ""
    val oppoAppSecret = getDartDefine("OPPO_APP_SECRET") ?: ""

    defaultConfig {
        applicationId = "com.creativekoalas.psygo$appIdSuffix"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 注入 app 名称到 manifest
        manifestPlaceholders["appName"] = appName
        manifestPlaceholders["VIVO_APP_ID"] = vivoAppId
        manifestPlaceholders["VIVO_API_KEY"] = vivoApiKey
        manifestPlaceholders["XIAOMI_APP_ID"] = xiaomiAppId
        manifestPlaceholders["XIAOMI_APP_KEY"] = xiaomiAppKey
        manifestPlaceholders["HONOR_APP_ID"] = honorAppId
        manifestPlaceholders["OPPO_APP_KEY"] = oppoAppKey
        manifestPlaceholders["OPPO_APP_SECRET"] = oppoAppSecret
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                val alias = keystoreProperties["keyAlias"]?.toString()
                val pass  = keystoreProperties["keyPassword"]?.toString()
                val file  = keystoreProperties["storeFile"]?.toString()
                val store = keystoreProperties["storePassword"]?.toString()

                require(!alias.isNullOrBlank()) { "Missing keyAlias in key.properties" }
                require(!pass.isNullOrBlank()) { "Missing keyPassword in key.properties" }
                require(!file.isNullOrBlank()) { "Missing storeFile in key.properties" }
                require(!store.isNullOrBlank()) { "Missing storePassword in key.properties" }

                keyAlias = alias
                keyPassword = pass
                storeFile = file(file)
                storePassword = store
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
        debug {
            // 一键登录 SDK 需要签名与阿里云控制台配置一致
            // debug 也使用 release 签名，避免 600017 错误
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}
