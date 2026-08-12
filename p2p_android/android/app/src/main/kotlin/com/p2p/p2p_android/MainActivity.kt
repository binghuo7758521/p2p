package com.p2p.p2p_android

import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
    }
}
