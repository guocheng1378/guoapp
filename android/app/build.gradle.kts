import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val dartDefines = providers.gradleProperty("dart-defines").orNull.orEmpty()
    .split(",").filter { it.isNotEmpty() }
    .associate {
        val decoded = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
        decoded.substringBefore("=") to decoded.substringAfter("=", "")
    }
val allSources = dartDefines["ALL_SOURCES"] == "true"

val releaseKey = rootProject.file("key.properties")
val releaseProperties = Properties()
if (releaseKey.exists()) {
    releaseKey.inputStream().use { releaseProperties.load(it) }
}

android {
    namespace = "com.duanju.duanju_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.duanju.duanju_app"
        // minSdk 26：adaptive-icon 三件套要求 API 26+（drawable/app_icon.xml
        // 无 legacy PNG 兜底）。降到 24 的前置=先补 mipmap 五密度 PNG
        // （对标 Xanerix/guoapp 的 mipmap-*/ic_launcher 模式），见 2172 周期
        // 报备，勿单独改此值。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        // versionName 附带 pubspec 构建号（flutter.versionCode 在此无 split-per-abi
        // 的 ABI 偏移；偏移是 split 输出阶段才加的）。deviceInfo 渠道把它原样返回，
        // 更新提示依赖 "x.y.z+build" 形态做构建号比较。
        versionName = "${flutter.versionName}+${flutter.versionCode}"
        manifestPlaceholders["appLabel"] = if (allSources) "真果鉴" else "红果鉴"
        manifestPlaceholders["appBanner"] = if (allSources) "@drawable/tv_banner_all_sources" else "@drawable/tv_banner"
    }

    signingConfigs {
        if (releaseKey.exists()) {
            create("release") {
                storeFile = file(requireNotNull(releaseProperties.getProperty("storeFile")))
                storePassword = requireNotNull(releaseProperties.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseProperties.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseProperties.getProperty("keyPassword"))
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            // jni/jnigen 绑定（shared_preferences_android、path_provider_android 等）
            // 在运行时按硬编码 JVM 签名反射查找方法，R8 重命名会破坏签名导致
            // NoSuchMethodError（getAll 的 Continuation 被混淆成 y4），必须关闭压缩。
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName(if (releaseKey.exists()) "release" else "debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter { source = "../.." }

tasks.withType<JavaCompile>().configureEach {
    if (name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val generated = registrant.readText()
                val integrationPlugin = Regex(
                    """(?s)    try \{\s*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s*\} catch \(Exception e\) \{[^}]*\}\s*"""
                )
                val release = generated.replace(integrationPlugin, "")
                if (release != generated) registrant.writeText(release)
            }
        }
    }
}
