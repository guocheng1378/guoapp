package com.duanju.duanju_app

import io.flutter.embedding.android.FlutterActivity
import android.app.UiModeManager
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.os.Build
import android.os.Bundle
import android.os.BatteryManager
import android.os.PowerManager
import android.os.SystemClock
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.provider.Settings
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.net.ConnectivityManager
import android.net.Uri
import android.util.Rational
import android.view.InputDevice
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var headroomReadAt = 0L
    private var thermalHeadroom: Double? = null
    private var deviceChannel: MethodChannel? = null
    private var televisionMode = false

    @Suppress("DEPRECATION")
    private fun isTelevisionDevice(): Boolean {
        val configuration = resources.configuration
        val mode = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType
            ?: (configuration.uiMode and Configuration.UI_MODE_TYPE_MASK)
        if (mode == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION) ||
            packageManager.hasSystemFeature("amazon.hardware.fire_tv")) {
            return true
        }
        if (mode == Configuration.UI_MODE_TYPE_CAR ||
            mode == Configuration.UI_MODE_TYPE_WATCH ||
            mode == Configuration.UI_MODE_TYPE_VR_HEADSET ||
            configuration.touchscreen != Configuration.TOUCHSCREEN_NOTOUCH ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_SENSOR_ACCELEROMETER) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_WATCH) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_PC)) {
            return false
        }
        val remoteNavigation = configuration.navigation == Configuration.NAVIGATION_DPAD ||
            InputDevice.getDeviceIds().any { id ->
                val device = InputDevice.getDevice(id)
                device != null && !device.isVirtual && device.supportsSource(InputDevice.SOURCE_DPAD)
            }
        return remoteNavigation || packageManager.hasSystemFeature(PackageManager.FEATURE_LIVE_TV)
    }

    override fun setRequestedOrientation(requestedOrientation: Int) {
        super.setRequestedOrientation(
            if (televisionMode) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else requestedOrientation
        )
    }

    private fun playbackPower(): Map<String, Any?> {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val activity = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            (headroomReadAt == 0L || now - headroomReadAt >= 10000L)) {
            headroomReadAt = now
            thermalHeadroom = runCatching {
                power?.getThermalHeadroom(0)?.toDouble()?.takeIf { it.isFinite() }
            }.getOrNull()
        }
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            power?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE
        } else 0
        return mapOf(
            "batterySaver" to (power?.isPowerSaveMode ?: false),
            "onBattery" to ((battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1) <= 0),
            "thermalStatus" to thermalStatus,
            "headroom" to thermalHeadroom,
            "lowMemory" to (activity?.isLowRamDevice ?: true),
            "gles" to (activity?.deviceConfigurationInfo?.reqGlEsVersion ?: 0)
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        televisionMode = if (savedInstanceState?.containsKey("duanju.televisionMode") == true) {
            savedInstanceState.getBoolean("duanju.televisionMode")
        } else isTelevisionDevice()
        super.onCreate(savedInstanceState)
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        // 挖孔屏横屏时挖孔转到左侧：默认 DEFAULT 模式窗口会在挖孔处 letterbox
        // 留黑条。SHORT_EDGES 让窗口延伸进挖孔，应用背景/雾面自然覆盖；
        // Flutter 侧 AppBar 经 SafeArea 仍自动避开挖孔，不遮挡内容。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (televisionMode) requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("duanju.televisionMode", televisionMode)
        super.onSaveInstanceState(outState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "duanju/device")
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "androidId" -> {
                            val id = runCatching {
                                Settings.Secure.getString(
                                    contentResolver,
                                    Settings.Secure.ANDROID_ID
                                )
                            }.getOrNull()
                            result.success(id)
                        }
                        "openQQ" -> result.success(
                            openQQInApp(call.argument<String>("uin").orEmpty())
                        )
                        "deviceInfo" -> {
                            // versionName 由 build.gradle.kts 拼成 "x.y.z+build"（pubspec 构建号，
                            // 不含 split-per-abi 的 ABI 偏移），更新提示依赖该形态比较构建号。
                            val version = packageManager.getPackageInfo(packageName, 0).versionName
                            result.success(mapOf("television" to isTelevisionDevice(), "version" to version))
                        }
                        "setTelevisionMode" -> {
                            val enabled = call.argument<Boolean>("enabled")
                            if (enabled == null) {
                                result.error("invalid_display_mode", "缺少电视模式状态", null)
                            } else {
                                val changed = televisionMode != enabled
                                televisionMode = enabled
                                if (enabled || changed) {
                                    requestedOrientation = if (enabled) {
                                        ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                    } else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                                }
                                result.success(null)
                            }
                        }
                        "playbackPower" -> result.success(runCatching { playbackPower() }.getOrNull())
                        "systemProxy" -> {
                            val connection = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                            val proxy = connection.defaultProxy
                            val host = proxy?.host.orEmpty()
                            val address = if (host.isNotEmpty() && (proxy?.port ?: 0) > 0) {
                                "http://${if (host.contains(':')) "[$host]" else host}:${proxy!!.port}"
                            } else ""
                            result.success(mapOf(
                                "http" to address,
                                "https" to address,
                                "bypass" to (proxy?.exclusionList?.toList() ?: emptyList<String>()),
                                "pac" to (proxy != null && proxy.pacFileUrl != Uri.EMPTY)
                            ))
                        }
                        "pictureInPictureStatus" -> result.success(pictureInPictureStatus())
                        "enterPictureInPicture" -> {
                            val width = call.argument<Int>("width") ?: 16
                            val height = call.argument<Int>("height") ?: 9
                            result.success(enterPlayerPictureInPicture(
                                width,
                                height,
                                call.argument<Int>("left"),
                                call.argument<Int>("top"),
                                call.argument<Int>("right"),
                                call.argument<Int>("bottom")
                            ))
                        }
                        "getBrightness" -> {
                            val lp = window.attributes
                            val current = if (lp.screenBrightness >= 0f) {
                                lp.screenBrightness.toDouble()
                            } else {
                                try {
                                    val sys = Settings.System.getInt(
                                        contentResolver,
                                        Settings.System.SCREEN_BRIGHTNESS
                                    )
                                    (sys / 255.0).coerceIn(0.0, 1.0)
                                } catch (e: Exception) {
                                    0.5
                                }
                            }
                            result.success(current)
                        }
                        "setBrightness" -> {
                            val value = call.argument<Double>("brightness")?.toFloat()
                            if (value != null) {
                                val lp = window.attributes
                                lp.screenBrightness = value.coerceIn(0.01f, 1.0f)
                                window.attributes = lp
                                result.success(true)
                            } else {
                                result.error("invalid_arg", "缺少亮度数值", null)
                            }
                        }
                        "resetBrightness" -> {
                            val lp = window.attributes
                            lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                            window.attributes = lp
                            result.success(true)
                        }
                        "battery" -> {
                            // 播放器状态区电量：BATTERY_PROPERTY_CAPACITY 不需要任何权限，
                            // 取不到（模拟器/极简 ROM）返回 null，Dart 侧整颗图标隐藏。
                            val manager = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                            val level = manager?.getIntProperty(
                                BatteryManager.BATTERY_PROPERTY_CAPACITY
                            ) ?: -1
                            if (level < 0) {
                                result.success(null)
                            } else {
                                result.success(
                                    mapOf(
                                        "level" to level.coerceIn(0, 100),
                                        "charging" to (manager?.isCharging ?: false)
                                    )
                                )
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    // 拉起 QQ：先资料卡（含“加好友”按钮），失败再试临时会话聊天；未安装返回 false。
    private fun openQQInApp(uin: String): Boolean {
        if (uin.isEmpty()) return false
        val schemes = listOf(
            "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=$uin",
            "mqqwpa://im/chat?chat_type=wpa&uin=$uin&version=1&src_type=web"
        )
        for (scheme in schemes) {
            val launched = runCatching {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(scheme)))
                true
            }.getOrElse { false }
            if (launched) return true
        }
        return false
    }

    private fun pictureInPictureSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun pictureInPictureStatus(): Map<String, Any> {
        return mapOf(
            "supported" to pictureInPictureSupported(),
            "active" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode)
        )
    }

    private fun enterPlayerPictureInPicture(
        width: Int,
        height: Int,
        left: Int?,
        top: Int?,
        right: Int?,
        bottom: Int?
    ): Map<String, Any> {
        if (!pictureInPictureSupported()) return pictureInPictureStatus()
        val safeWidth = width.coerceIn(1, 10000)
        val safeHeight = height.coerceIn(1, 10000)
        return runCatching {
            val builder = PictureInPictureParams.Builder()
            builder.setAspectRatio(Rational(safeWidth, safeHeight))
            if (left != null && top != null && right != null && bottom != null &&
                right > left && bottom > top) {
                builder.setSourceRectHint(Rect(left, top, right, bottom))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(true)
            }
            val entered = enterPictureInPictureMode(builder.build())
            pictureInPictureStatus() + ("requested" to entered)
        }.getOrElse { pictureInPictureStatus() }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        deviceChannel?.invokeMethod(
            "pictureInPictureChanged",
            mapOf("active" to isInPictureInPictureMode)
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        deviceChannel?.setMethodCallHandler(null)
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
