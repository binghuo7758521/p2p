import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'version.dart';

/// 测试阶段运行日志工具（手机端）
///
/// 日志写入应用专属外部目录（文件管理器可直接访问）：
///   /storage/emulated/0/Android/data/<包名>/files/logs/app.log
/// 超过 2MB 自动轮转（旧档保留为 app.log.1）。
///
/// 用法：
///   AppLog.i('upload', '开始上传: xxx.mp4 28.3MB');
///   AppLog.e('upload', '发送失败', e);
class AppLog {
  AppLog._();

  static final AppLog _instance = AppLog._();

  File? _file;
  final List<Future<void> Function()> _pending = [];
  bool _draining = false;

  static const int _maxBytes = 2 * 1024 * 1024;

  /// 应用启动时调用一次
  static Future<void> init() async {
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return;
      final dir = Directory('${base.path}/logs');
      await dir.create(recursive: true);
      _instance._file = File('${dir.path}/app.log');
      if (await _instance._file!.exists() &&
          await _instance._file!.length() > _maxBytes) {
        final old = File('${_instance._file!.path}.1');
        try {
          if (await old.exists()) await old.delete();
        } catch (_) {}
        try {
          await _instance._file!.rename(old.path);
        } catch (_) {}
        _instance._file = File('${dir.path}/app.log');
      }
      i('log', '=== 日志系统启动: $_instance._file!.path ===');
      // 记录运行环境，便于定位版本差异问题
      try {
        i('env',
            '系统=${Platform.operatingSystem} ${Platform.operatingSystemVersion}, '
            '调试模式=$kDebugMode');
      } catch (_) {}
    } catch (e) {
      debugPrint('AppLog.init 失败: $e');
    }
  }

  static void i(String tag, String msg) => _instance._write('I', tag, msg);

  /// 警告（预期内的异常分支，需人工关注但不致命）
  static void w(String tag, String msg, [Object? error]) =>
      _instance._write('W', tag, error == null ? msg : '$msg | 异常: $error');

  static void e(String tag, String msg, [Object? error]) =>
      _instance._write('E', tag, error == null ? msg : '$msg | 异常: $error');

  /// 读取当前日志内容（供 UI 一键复制排查问题），最多返回最近 [maxChars] 字符
  static Future<String> readLog({int maxChars = 500000}) async {
    final f = _instance._file;
    if (f == null || !await f.exists()) return '（日志文件尚未创建）';
    try {
      final len = await f.length();
      if (len > maxChars) {
        // 截取末尾部分，避免复制超长日志
        final raf = await f.open();
        try {
          await raf.setPosition(len - maxChars);
          final bytes = await raf.read(maxChars);
          return utf8.decode(bytes, allowMalformed: true);
        } finally {
          await raf.close();
        }
      }
      return f.readAsString();
    } catch (e) {
      return '（读取日志失败: $e）';
    }
  }

  void _write(String level, String tag, String msg) {
    // 每条日志带版本号：app.log 跨版本累积追加，无版本无法区分新旧行为
    final line = '${_ts()} [v$appVersion][$level][$tag] $msg';
    debugPrint(line);
    final f = _file;
    if (f == null) return;
    _pending.add(() async {
      try {
        final raf = await f.open(mode: FileMode.append);
        try {
          await raf.writeString('$line\n');
        } finally {
          await raf.close();
        }
      } catch (_) {}
    });
    _drain();
  }

  void _drain() {
    if (_draining) return;
    _draining = true;
    Future<void> loop() async {
      while (_pending.isNotEmpty) {
        final fn = _pending.removeAt(0);
        await fn();
      }
      _draining = false;
    }
    loop();
  }

  static String _ts() {
    final n = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p2(n.month)}-${p2(n.day)} '
        '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}.'
        '${n.millisecond.toString().padLeft(3, '0')}';
  }
}
