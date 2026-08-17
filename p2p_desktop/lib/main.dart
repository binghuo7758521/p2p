import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'auto_start.dart';
import 'connect_page.dart';
import 'host_controller.dart';
import 'update_service.dart';
import 'version.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();

  // 设置 Windows 窗口标题为 "无限大盘 - 局域网 vX.Y"（版本号单一来源：version.dart）
  _setWindowTitle();

  AppLog.i('app', '电脑端启动 v$appVersion');
  // 检查并自动配置开机自启（异步执行，不阻塞界面启动）
  AutoStartService.ensureAutoStart();
  runApp(const P2pDesktopApp());
  // v6.12+：升级检测提升为应用级——程序启动即检测（不等进主页面），
  // 并保留每 6 小时定时检查；弹窗使用全局 navigatorKey，任何页面均可弹出
  WidgetsBinding.instance.addPostFrameCallback((_) {
    UpdateService.instance.start();
  });
}

/// 通过 native 通道设置窗口标题（main.cpp 注册的 p2p/window_title）
Future<void> _setWindowTitle() async {
  try {
    await const MethodChannel('p2p/window_title')
        .invokeMethod('set', {'title': '无限大盘 - 局域网 v$appVersion'});
    AppLog.i('app', '窗口标题已设置: 无限大盘 - 局域网 v$appVersion');
  } catch (e) {
    AppLog.w('app', '设置窗口标题失败（忽略）', e);
  }
}

class P2pDesktopApp extends StatelessWidget {
  const P2pDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = HostController();
    return MaterialApp(
      title: '无限大盘 - 电脑端',
      debugShowCheckedModeBanner: false,
      // 全局导航键：升级服务等应用级弹窗不依赖页面 context
      navigatorKey: UpdateService.instance.navigatorKey,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF38BDF8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: ConnectPage(controller: controller),
    );
  }
}
