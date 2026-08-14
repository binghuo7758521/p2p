import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'app_log.dart';
import 'update_check.dart';

/// 静默升级阶段
enum UpdatePhase { downloading, verifying, extracting, launching }

/// 静默升级编排：下载 → MD5 校验 → 解压临时目录 → 重启脚本 → 退出主程序
///
/// 返回 true 表示升级已编排成功，调用方应立即退出主程序
/// （由 update.bat 等待进程完全退出后覆盖程序目录并启动新版本）；
/// 返回 false 表示失败，程序应继续正常运行。
///
/// 数据文件（admin.json / users.json / shares.json / device_name）均保存在
/// 用户目录而非程序目录，覆盖 Release 目录不会丢失任何配置。
Future<bool> runSilentUpgrade({
  required String downloadUrl,
  String? expectedMd5,
  void Function(UpdatePhase phase, double? progress, String message)?
      onPhase,
}) async {
  final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
  final appDir = File(Platform.resolvedExecutable).parent.path;
  final workDir = Directory('${Directory.systemTemp.path}\\p2p_updater');
  final zipPath = '${workDir.path}\\p2p_desktop.zip';
  final newDir = '${workDir.path}\\new';
  final batPath = '${workDir.path}\\update.bat';

  // 升级已编排（bat 已启动）：临时目录交给 bat 清理，主程序退出
  var scheduled = false;
  try {
    // 清理上次升级残留（如升级中断）
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    workDir.createSync(recursive: true);

    // 1. 下载升级包（带进度回调）
    onPhase?.call(UpdatePhase.downloading, 0, '正在下载升级包…');
    await downloadUpgradeZip(downloadUrl, zipPath, (received, total) {
      onPhase?.call(
        UpdatePhase.downloading,
        total > 0 ? received / total : null,
        '正在下载升级包…',
      );
    });

    // 2. MD5 完整性校验（服务器未提供 MD5 时拒绝静默升级，回退手动下载）
    final expected = expectedMd5?.trim().toLowerCase();
    if (expected == null || expected.isEmpty) {
      AppLog.e('update', '服务器未提供升级包 MD5，拒绝静默升级');
      return false;
    }
    onPhase?.call(UpdatePhase.verifying, null, '正在校验升级包完整性…');
    final digest = md5.convert(await File(zipPath).readAsBytes()).toString();
    if (digest != expected) {
      AppLog.e('update', 'MD5 校验失败: 期望 $expected 实际 $digest');
      return false;
    }
    AppLog.i('update', 'MD5 校验通过: $digest');

    // 3. 解压到临时目录（跳过路径穿越条目，防止恶意 zip 写出目录外）
    onPhase?.call(UpdatePhase.extracting, null, '正在解压升级包…');
    final archive =
        ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());
    Directory(newDir).createSync(recursive: true);
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (name.startsWith('/') || name.contains('../')) {
        AppLog.w('update', '跳过可疑路径条目: $name');
        continue;
      }
      final target = File('$newDir\\${name.replaceAll('/', '\\')}');
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(entry.content, flush: true);
    }
    // 解压产物必须包含主程序 exe，否则拒绝升级（防止错误/损坏的升级包）
    var appExe = File('$newDir\\$exeName');
    if (!appExe.existsSync()) {
      // 兼容带一层外层文件夹的升级包（zip 内套目录）：找到含 exe 的唯一
      // 子目录并提升内容到 newDir 根，避免“升级包缺少 exe”误拒
      final subs = Directory(newDir)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList();
      if (subs.length == 1 &&
          File('${subs.first.path}\\$exeName').existsSync()) {
        final sub = subs.first;
        for (final f in sub.listSync(recursive: true, followLinks: false)) {
          if (f is! File) continue;
          final rel = f.path.substring(sub.path.length + 1);
          final t = File('$newDir\\$rel');
          t.parent.createSync(recursive: true);
          f.copySync(t.path);
        }
        AppLog.w('update',
            '升级包含外层文件夹 ${sub.path.split('\\').last}，已提升内容');
        appExe = File('$newDir\\$exeName');
      }
    }
    if (!appExe.existsSync()) {
      AppLog.e('update', '升级包缺少 $exeName，拒绝升级');
      return false;
    }

    // 4. 写重启脚本：等待旧进程退出 → 覆盖程序目录 → 启动新版本 → 清理
    onPhase?.call(UpdatePhase.launching, null, '正在准备重启…');
    File(batPath).writeAsStringSync(_buildBat(appDir, newDir, zipPath));

    // 5. 用 wscript（无窗口）启动重启脚本，主程序随即退出：
    //    脚本先轮询等待本进程完全退出（解除 exe 锁），再覆盖并启动新版本
    final vbsPath = '${workDir.path}\\run_update.vbs';
    File(vbsPath).writeAsStringSync(
        'Set sh = CreateObject("WScript.Shell")\r\n'
        'sh.Run "cmd.exe /c " & Chr(34) & "$batPath" & Chr(34), 0, False\r\n');
    AppLog.i('update', '静默升级编排完成，程序即将退出，由 update.bat 完成替换重启');
    await Process.start('wscript.exe', [vbsPath]);
    scheduled = true;
    return true;
  } catch (e) {
    AppLog.e('update', '静默升级失败', e);
    return false;
  } finally {
    // 失败时清理临时目录（成功时由 update.bat 清理）
    if (!scheduled && workDir.existsSync()) {
      try {
        workDir.deleteSync(recursive: true);
      } catch (e) {
        AppLog.w('update', '清理升级临时目录失败（忽略）', e);
      }
    }
  }
}

/// 生成重启脚本（Windows 批处理，CRLF 行尾）：
/// 等待旧进程退出（最长 10 秒，仍占用则强制结束，解除 exe 文件锁）
/// → robocopy 覆盖程序目录（退出码 0-7 为成功）
/// → 启动新版本 → 清理临时目录与脚本自身
String _buildBat(String appDir, String newDir, String zipPath) {
  final lines = [
    '@echo off',
    'setlocal',
    'set "APP_DIR=$appDir"',
    'set "NEW_DIR=$newDir"',
    'set "ZIP_FILE=$zipPath"',
    'rem ===== P2P 文件助手静默升级 =====',
    'rem 等待旧进程完全退出（解除 exe 文件锁），最长 10 秒',
    'set /a n=0',
    ':wait_loop',
    'tasklist /fi "imagename eq p2p_desktop.exe" 2>nul | find /i "p2p_desktop.exe" >nul',
    'if errorlevel 1 goto app_exited',
    'set /a n+=1',
    'if %n% geq 10 goto force_kill',
    'timeout /t 1 /nobreak >nul',
    'goto wait_loop',
    ':force_kill',
    'taskkill /f /im p2p_desktop.exe >nul 2>&1',
    'timeout /t 1 /nobreak >nul',
    ':app_exited',
    'rem 覆盖程序目录（robocopy 退出码 0-7 均为成功，8+ 为失败）',
    'robocopy "%NEW_DIR%" "%APP_DIR%" /e /is /it /r:3 /w:1 >nul',
    'if errorlevel 8 goto failed',
    'rem 启动新版本',
    'start "" "%APP_DIR%\\p2p_desktop.exe"',
    'rem 清理临时文件',
    'rmdir /s /q "%NEW_DIR%" >nul 2>&1',
    'del /q "%ZIP_FILE%" >nul 2>&1',
    'del /q "%~dp0run_update.vbs" >nul 2>&1',
    'del /q "%~f0" >nul 2>&1',
    'exit /b 0',
    ':failed',
    'exit /b 1',
  ];
  return '${lines.join('\r\n')}\r\n';
}
