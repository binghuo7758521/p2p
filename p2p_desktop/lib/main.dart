import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'auto_start.dart';
import 'connect_page.dart';
import 'host_controller.dart';
import 'version.dart';

// ── 单实例保护（Windows 命名互斥体）────────────────────────
// 重复启动时提示并退出，避免多实例堆积导致 exe 被占用/无法升级
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final _createMutexW = _kernel32.lookupFunction<
    IntPtr Function(Pointer<Void>, Int32, Pointer<Utf16>),
    int Function(Pointer<Void>, int, Pointer<Utf16>)>('CreateMutexW');
final _getLastError =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final _messageBoxW = _user32.lookupFunction<
    IntPtr Function(Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>, Uint32),
    int Function(
        Pointer<Void>, Pointer<Utf16>, Pointer<Utf16>, int)>('MessageBoxW');

const int _kErrorAlreadyExists = 183; // ERROR_ALREADY_EXISTS

/// 空指针（Windows API 的 NULL 参数）
final Pointer<Void> _nullPtr = Pointer<Void>.fromAddress(0);

/// 单实例互斥体检查：已有实例在运行时返回 true（本实例应退出）
bool _singleInstanceGuard() {
  final name = 'Local\\P2P_Desktop_Single_Instance'.toNativeUtf16();
  _createMutexW(_nullPtr, 0, name);
  malloc.free(name);
  return _getLastError() == _kErrorAlreadyExists;
}

void _showAlreadyRunningTip() {
  try {
    final title = 'P2P 文件助手'.toNativeUtf16();
    final msg = 'P2P 文件助手已在运行（可能最小化在任务栏/托盘中）。\n'
            '请先关闭已打开的窗口，再重新启动程序。'
        .toNativeUtf16();
    _messageBoxW(
        _nullPtr, msg, title, 0x40 /* MB_ICONINFORMATION */ | 0x0 /* MB_OK */);
    malloc.free(title);
    malloc.free(msg);
  } catch (e) {
    AppLog.w('app', '弹出重复运行提示失败（忽略）', e);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();

  // 设置 Windows 窗口标题为 "p2p_desktop vX.Y"（版本号单一来源：version.dart）
  _setWindowTitle();

  // 单实例保护：已有实例时提示并退出，防止进程堆积
  if (_singleInstanceGuard()) {
    AppLog.w('app', '检测到已有实例在运行，本实例退出');
    _showAlreadyRunningTip();
    exit(0);
  }

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
