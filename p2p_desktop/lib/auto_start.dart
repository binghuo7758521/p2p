import 'dart:io';

import 'app_log.dart';

/// Windows 开机自启管理：通过注册表 HKCU\...\Run 键实现
///
/// - 写入当前用户 Run 键，无需管理员权限
/// - 程序拷贝到新路径后自动更新注册表指向（路径不匹配视为未启用）
class AutoStartService {
  static const _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'P2PFileAssistant';

  /// 当前可执行文件完整路径
  static String get _exePath => Platform.resolvedExecutable;

  /// 检查是否已配置开机自启（要求注册表指向当前 exe 路径）
  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run(
        'reg',
        ['query', _runKey, '/v', _valueName],
      );
      return r.exitCode == 0 && r.stdout.toString().contains(_exePath);
    } catch (e) {
      AppLog.w('autostart', '检查开机自启失败', e);
      return false;
    }
  }

  /// 配置开机自启（写入注册表 Run 键，值为当前 exe 路径）
  static Future<bool> enable() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('reg', [
        'add',
        _runKey,
        '/v',
        _valueName,
        '/t',
        'REG_SZ',
        '/d',
        '"$_exePath"',
        '/f',
      ]);
      final ok = r.exitCode == 0;
      if (ok) {
        AppLog.i('autostart', '已配置开机自动运行: $_exePath');
      } else {
        AppLog.w('autostart', '配置开机自启失败: ${r.stderr}');
      }
      return ok;
    } catch (e) {
      AppLog.w('autostart', '配置开机自启失败', e);
      return false;
    }
  }

  /// 取消开机自启（删除注册表 Run 键值）
  static Future<bool> disable() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run(
        'reg',
        ['delete', _runKey, '/v', _valueName, '/f'],
      );
      final ok = r.exitCode == 0;
      AppLog.i('autostart', ok ? '已取消开机自动运行' : '取消开机自启失败: ${r.stderr}');
      return ok;
    } catch (e) {
      AppLog.w('autostart', '取消开机自启失败', e);
      return false;
    }
  }

  /// 检查并自动配置（程序启动时调用；未启用则自动启用）
  static Future<void> ensureAutoStart() async {
    if (!Platform.isWindows) return;
    try {
      final enabled = await isEnabled();
      AppLog.i('autostart', '开机自启检查: ${enabled ? '已启用' : '未启用'} (exe=$_exePath)');
      if (!enabled) await enable();
    } catch (e) {
      AppLog.w('autostart', '开机自启处理异常', e);
    }
  }
}
