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
///
/// v6.27+：MD5 校验失败自动重试（最多 3 次，间隔 5 秒）——发布窗口期
/// （服务器本地包与 OSS 下载源短暂不同步）首次校验可能拿到旧包的期望值，
/// 通过 refreshInfo 重新获取最新升级信息后自愈，无需用户干预；
/// refreshInfo 为空时保持旧行为（校验失败即放弃）。
Future<bool> runSilentUpgrade({
  required String downloadUrl,
  String? expectedMd5,
  void Function(UpdatePhase phase, double? progress, String message)?
      onPhase,
  Future<UpdateInfo?> Function()? refreshInfo,
}) async {
  final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
  final appDir = File(Platform.resolvedExecutable).parent.path;
  final workDir = Directory('${Directory.systemTemp.path}\\p2p_updater');
  final zipPath = '${workDir.path}\\p2p_desktop.zip';
  final newDir = '${workDir.path}\\new';
  final ps1Path = '${workDir.path}\\run_update.ps1';

  // 升级已编排（脚本已启动）：临时目录交给重启脚本清理，主程序退出
  var scheduled = false;
  try {
    // 清理上次升级残留（如升级中断）
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    workDir.createSync(recursive: true);

    // 1-2. 下载升级包 → MD5 完整性校验，失败自动重试（v6.27+）
    // 校验不一致时若配置了 refreshInfo：重新获取最新升级信息重试；
    // 已下载的包与最新 md5 一致则直接复用（服务器信息滞后），否则重新下载
    for (var attempt = 0; attempt <= 2; attempt++) {
      if (attempt > 0) {
        // 重试：先取最新升级信息，拿不到则放弃（保持旧行为由调用方兜底）
        final fresh = await refreshInfo?.call();
        if (fresh == null || fresh.url == null ||
            fresh.md5 == null || fresh.md5!.isEmpty) {
          AppLog.e('update', '重试时无法获取最新升级信息，放弃静默升级');
          return false;
        }
        downloadUrl = fresh.url!;
        expectedMd5 = fresh.md5;
        onPhase?.call(UpdatePhase.verifying, null,
            '升级包校验不一致，正在获取最新升级包（第 $attempt 次重试）…');
        await Future.delayed(const Duration(seconds: 5));
        final localDigest =
            md5.convert(await File(zipPath).readAsBytes()).toString();
        if (localDigest == expectedMd5) {
          // 服务器信息滞后：已下载的包即为最新包，直接复用
          AppLog.i('update', '已下载升级包即为最新包（服务器信息滞后），直接复用');
        } else {
          await downloadUpgradeZip(downloadUrl, zipPath, (received, total) {
            onPhase?.call(
              UpdatePhase.downloading,
              total > 0 ? received / total : null,
              '正在重新下载升级包…',
            );
          });
        }
      } else {
        // 首次尝试：下载升级包（带进度回调）
        onPhase?.call(UpdatePhase.downloading, 0, '正在下载升级包…');
        await downloadUpgradeZip(downloadUrl, zipPath, (received, total) {
          onPhase?.call(
            UpdatePhase.downloading,
            total > 0 ? received / total : null,
            '正在下载升级包…',
          );
        });
      }

      // MD5 完整性校验（服务器未提供 MD5 时拒绝静默升级，回退手动下载）
      final expected = expectedMd5?.trim().toLowerCase();
      if (expected == null || expected.isEmpty) {
        AppLog.e('update', '服务器未提供升级包 MD5，拒绝静默升级');
        return false;
      }
      onPhase?.call(UpdatePhase.verifying, null, '正在校验升级包完整性…');
      final digest = md5.convert(await File(zipPath).readAsBytes()).toString();
      if (digest != expected) {
        AppLog.e('update',
            'MD5 校验失败（第 ${attempt + 1}/3 次）: 期望 $expected 实际 $digest');
        if (attempt < 2) continue; // 仍有重试机会：5 秒后重新获取信息重试
        return false;
      }
      AppLog.i('update', 'MD5 校验通过: $digest');
      break;
    }

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
    // 注意：重启脚本必须用 PowerShell（UTF-8 带 BOM）而非 bat ——
    // cmd 按 ANSI(GBK) 解析 bat 文件，程序目录含中文（如“无限大盘”）时
    // 路径被误读成乱码，升级包会装进乱码目录导致“升级成功但仍是旧版”（v6.22 修复）
    File(ps1Path).writeAsStringSync(
        '\uFEFF${_buildPs1(appDir, newDir, zipPath)}',
        flush: true);

    // 5. 用 wscript（无窗口）启动重启脚本，主程序随即退出：
    //    脚本先轮询等待本进程完全退出（解除 exe 锁），再覆盖并启动新版本
    final vbsPath = '${workDir.path}\\run_update.vbs';
    File(vbsPath).writeAsStringSync(
        'Set sh = CreateObject("WScript.Shell")\r\n'
        'sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & "$ps1Path" & Chr(34), 0, False\r\n');
    AppLog.i('update', '静默升级编排完成，程序即将退出，由 run_update.ps1 完成替换重启');
    await Process.start('wscript.exe', [vbsPath]);
    scheduled = true;
    return true;
  } catch (e) {
    AppLog.e('update', '静默升级失败', e);
    return false;
  } finally {
    // 失败时清理临时目录（成功时由重启脚本清理）
    if (!scheduled && workDir.existsSync()) {
      try {
        workDir.deleteSync(recursive: true);
      } catch (e) {
        AppLog.w('update', '清理升级临时目录失败（忽略）', e);
      }
    }
  }
}

/// 生成重启脚本（PowerShell，UTF-8 带 BOM 写入）：
/// 等待旧进程退出（最长 10 秒，仍占用则强制结束，解除 exe 文件锁）
/// → robocopy 覆盖程序目录（退出码 0-7 为成功）
/// → 启动新版本 → 清理临时目录与脚本自身
///
/// 脚本内全部为 Unicode 字符串，PowerShell 解析无编码问题；
/// 入口 vbs 调 powershell -File，-File 参数路径在 %TEMP% 下无中文，安全。
String _buildPs1(String appDir, String newDir, String zipPath) {
  // PS 单引号字符串内嵌路径：路径含单引号时需加倍（实际几乎不会出现）
  final esc = (String s) => s.replaceAll("'", "''");
  final lines = [
    '# ===== 无限大盘静默升级 =====',
    '\$ErrorActionPreference = "SilentlyContinue"',
    "\$appDir = '${esc(appDir)}'",
    "\$newDir = '${esc(newDir)}'",
    "\$zipFile = '${esc(zipPath)}'",
    '# 等待旧进程完全退出（解除 exe 文件锁），最长 10 秒',
    '\$n = 0',
    'while (\$true) {',
    '  if (-not (Get-Process -Name p2p_desktop -ErrorAction SilentlyContinue)) { break }',
    '  \$n++',
    '  if (\$n -ge 10) {',
    '    Stop-Process -Name p2p_desktop -Force -ErrorAction SilentlyContinue',
    '    Start-Sleep -Seconds 1',
    '    break',
    '  }',
    '  Start-Sleep -Seconds 1',
    '}',
    '# 覆盖程序目录（robocopy 退出码 0-7 均为成功，8+ 为失败）',
    'robocopy "\$newDir" "\$appDir" /e /is /it /r:3 /w:1 | Out-Null',
    'if (\$LASTEXITCODE -ge 8) { exit 1 }',
    '# 启动新版本',
    'Start-Process -FilePath "\$appDir\\p2p_desktop.exe"',
    '# 清理临时文件',
    'Remove-Item -Recurse -Force "\$newDir" -ErrorAction SilentlyContinue',
    'Remove-Item -Force "\$zipFile" -ErrorAction SilentlyContinue',
    'Remove-Item -Force "\$PSScriptRoot\\run_update.vbs" -ErrorAction SilentlyContinue',
    'Remove-Item -Force \$PSCommandPath -ErrorAction SilentlyContinue',
  ];
  return lines.join('\r\n') + '\r\n';
}
