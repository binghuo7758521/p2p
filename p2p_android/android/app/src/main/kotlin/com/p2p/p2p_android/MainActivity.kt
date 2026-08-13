package com.p2p.p2p_android

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 存储空间查询：手机端下载前预检剩余空间（空间不足时提前提示，
        // 避免下载中途写盘失败导致"电脑端完成、手机端卡在正在下载"）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "p2p/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFreeSpace" -> {
                        val dir = call.argument<String>("dir") ?: filesDir.absolutePath
                        try {
                            result.success(StatFs(dir).availableBytes.toDouble())
                        } catch (e: Exception) {
                            result.error("statfs", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 升级包安装（v5.2+）：拉起系统安装器前先检查"安装未知应用"授权，
        // 未授权时返回 needPermission 由 Dart 引导用户去系统设置开启（Android 8+）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "p2p/install")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path") ?: ""
                        val apkFile = File(path)
                        if (!apkFile.exists()) {
                            result.error("no-file", "升级包文件不存在", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            result.success(mapOf("needPermission" to true))
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", apkFile)
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(mapOf("needPermission" to false))
                        } catch (e: Exception) {
                            result.error("open-fail", e.message ?: "无法打开安装器", null)
                        }
                    }
                    "canInstallUnknown" -> {
                        val ok = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                        result.success(ok)
                    }
                    "openInstallSettings" -> {
                        try {
                            startActivity(Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("settings-fail", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

