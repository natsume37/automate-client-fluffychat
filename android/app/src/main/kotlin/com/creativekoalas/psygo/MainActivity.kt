package com.creativekoalas.psygo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log

class MainActivity : FlutterActivity() {

    private val TAG = "MainActivity"
    private val APP_CONTROL_CHANNEL = "com.creativekoalas.psygo/app_control"
    private val INSTALL_CHANNEL = "com.psygo.app/install"
    private val REQUEST_INSTALL_PERMISSION = 1001
    private var installPermissionResult: MethodChannel.Result? = null

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }

    /**
     * 使用 Surface 渲染模式而不是默认的 Texture 模式
     * 这可以解决从后台恢复时的黑屏问题
     */
    override fun getRenderMode(): RenderMode {
        return RenderMode.surface
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate called")
    }

    override fun onResume() {
        super.onResume()
        Log.d(TAG, "onResume called")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent called")
        setIntent(intent)
    }


    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 创建阿里云推送通知渠道（Android 8.0+）
        createNotificationChannel()

        // 复用同一个 FlutterEngine 时，configureFlutterEngine 可能被重复调用。
        // 插件注册需要幂等，避免 "plugin ... already registered" 警告。
        if (!flutterEngine.plugins.has(OneClickLoginPlugin::class.java)) {
            flutterEngine.plugins.add(OneClickLoginPlugin())
            Log.d(TAG, "OneClickLoginPlugin registered")
        } else {
            Log.d(TAG, "OneClickLoginPlugin already registered, skipping")
        }

        // 注册应用控制 channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "moveToBackground" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 注册安装权限 channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestPackageInstalls" -> {
                    result.success(canRequestPackageInstalls())
                }
                "requestInstallPermission" -> {
                    requestInstallPermission(result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 检查是否有安装未知应用的权限
     */
    private fun canRequestPackageInstalls(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true // Android 8.0 以下不需要此权限
        }
    }

    /**
     * 请求安装未知应用权限
     */
    private fun requestInstallPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (packageManager.canRequestPackageInstalls()) {
                result.success(true)
            } else {
                installPermissionResult = result
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivityForResult(intent, REQUEST_INSTALL_PERMISSION)
            }
        } else {
            result.success(true)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL_PERMISSION) {
            val canInstall = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                packageManager.canRequestPackageInstalls()
            } else {
                true
            }
            installPermissionResult?.success(canInstall)
            installPermissionResult = null
        }
    }

    /**
     * 创建阿里云推送通知渠道
     * Android 8.0+ 必须创建 NotificationChannel 才能显示通知
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // 创建高优先级通知渠道
            val channelId = "automate_push_channel"
            val channelName = "消息通知"
            val channelDescription = "接收 Psygo 的消息推送通知"
            val importance = NotificationManager.IMPORTANCE_HIGH

            val channel = NotificationChannel(channelId, channelName, importance).apply {
                description = channelDescription
                enableLights(true)
                lightColor = Color.BLUE
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 250, 250)
                setShowBadge(true)
            }

            notificationManager.createNotificationChannel(channel)
        }
    }

    companion object {
        var engine: FlutterEngine? = null
        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context, emptyArray(), true, false)
            engine = eng
            return eng
        }
    }
}
