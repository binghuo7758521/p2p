import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'auto_start.dart';
import 'connect_page.dart';
import 'host_controller.dart';
import 'version.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();

  // 设置 Windows 窗口标题为 "p2p_desktop vX.Y"（版本号单一来源：version.dart）
  _setWindowTitle();

  AppLog.i('app', '电脑端启动 v$appVersion');
  // 检查并自动配置开机自启（异步执行，不阻塞界面启动）
  AutoStartService.ensureAutoStart();
  runApp(const P2pDesktopApp());
}

/// 通过 native 通道设置窗口标题（main.cpp 注册的 p2p/window_title）
Future<void> _setWindowTitle() async {
  try {
    await const MethodChannel('p2p/window_title')
        .invokeMethod('set', {'title': 'p2p_desktop v$appVersion'});
    AppLog.i('app', '窗口标题已设置: p2p_desktop v$appVersion');
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
      title: 'P2P 文件助手 - 电脑端',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF38BDF8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: ConnectPage(controller: controller),
    );
  }
}
