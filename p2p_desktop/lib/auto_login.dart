import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Windows 重启后自动登录管理：配置 AutoAdminLogon（HKLM Winlogon）
///
/// - 写 HKLM 需要管理员权限，双路径执行：
///   1. 当前进程已提权（isElevated）→ 直接执行，无弹窗（远程设置前置条件）
///   2. 未提权 → PowerShell Start-Process -Verb RunAs 触发 UAC，由人确认
/// - 密码以 base64 内嵌到脚本（-EncodedCommand），不落盘、不进日志
/// - 关闭开关即删除密码项与启用标记，恢复普通登录
class AutoLoginService {
  static const _winlogonKey =
      r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon';

  /// 当前 Windows 用户名（本地账户与域账户通用）
  static String get _userName => Platform.environment['USERNAME'] ?? '';

  /// 当前进程是否以管理员权限运行（net session 仅在管理员下成功）
  static Future<bool> isElevated() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('net', ['session']);
      return r.exitCode == 0;
    } catch (e) {
      AppLog.w('autologin', '管理员权限检测失败', e);
      return false;
    }
  }

  /// 检查是否已配置自动登录（AutoAdminLogon=1 且目标用户是当前用户）
  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run(
        'reg',
        ['query', _winlogonKey, '/v', 'AutoAdminLogon'],
      );
      if (r.exitCode != 0) return false;
      final lines = r.stdout.toString().split('\n');
      final on = lines.any((l) =>
          l.contains('AutoAdminLogon') && l.trimRight().endsWith('1'));
      if (!on) return false;
      final u = await Process.run(
        'reg',
        ['query', _winlogonKey, '/v', 'DefaultUserName'],
      );
      return u.exitCode == 0 && u.stdout.toString().contains(_userName);
    } catch (e) {
      AppLog.w('autologin', '检查自动登录失败', e);
      return false;
    }
  }

  /// 启用自动登录：已提权直接写，否则 UAC 提权（本地场景）
  ///
  /// [password] 为 Windows 登录密码，仅写入本机注册表明文存储
  static Future<bool> enable(String password) async {
    if (!Platform.isWindows) return false;
    final outFile = _resultFile();
    final script = _buildEnableScript(password, outFile);
    return await isElevated()
        ? _runScript(script, outFile, elevate: false)
        : _runScript(script, outFile, elevate: true);
  }

  /// 关闭自动登录：已提权直接删，否则 UAC 提权
  static Future<bool> disable() async {
    if (!Platform.isWindows) return false;
    final outFile = _resultFile();
    final script = _buildDisableScript(outFile);
    return await isElevated()
        ? _runScript(script, outFile, elevate: false)
        : _runScript(script, outFile, elevate: true);
  }

  /// 结果文件（含进程号，避免并发冲突）
  static String _resultFile() =>
      '${Directory.systemTemp.path}\\p2p_autologin_$pid.out';

  /// 启用脚本：密码 base64 内嵌解码，避免任何引号/特殊字符转义问题
  static String _buildEnableScript(String password, String outFile) {
    final pwB64 = base64Encode(utf8.encode(password));
    return (r'''
$ErrorActionPreference = 'Stop'
try {
  $p = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PW_B64'))
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '1' -Type String
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultUserName -Value $env:USERNAME -Type String
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultDomainName -Value $env:USERDOMAIN -Type String
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -Value $p -Type String
  'ok' | Out-File -FilePath 'OUT_FILE' -Encoding ascii
} catch {
  ('err: ' + $_.Exception.Message) | Out-File -FilePath 'OUT_FILE' -Encoding ascii
}
''')
        .replaceAll('PW_B64', pwB64)
        .replaceAll('OUT_FILE', outFile);
  }

  /// 关闭脚本：删除启用标记与密码项，恢复登录界面
  static String _buildDisableScript(String outFile) => (r'''
$ErrorActionPreference = 'Stop'
try {
  Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -ErrorAction SilentlyContinue
  Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -ErrorAction SilentlyContinue
  'ok' | Out-File -FilePath 'OUT_FILE' -Encoding ascii
} catch {
  ('err: ' + $_.Exception.Message) | Out-File -FilePath 'OUT_FILE' -Encoding ascii
}
''').replaceAll('OUT_FILE', outFile);

  /// 执行 PowerShell 脚本：elevate=true 时经 Start-Process -Verb RunAs 弹 UAC
  static Future<bool> _runScript(
      String script, String outFile, {required bool elevate}) async {
    try {
      if (File(outFile).existsSync()) File(outFile).deleteSync();
      // -EncodedCommand 要求 UTF-16LE 的 base64（曾用 UTF-8 导致 PowerShell
      // 解码出乱码命令直接 exit=1、结果文件不存在 → 设置恒失败）。
      // Dart String 本身即 UTF-16 code units，直接按小端序展开成字节
      final bytes = <int>[];
      for (final u in script.codeUnits) {
        bytes.add(u & 0xFF);
        bytes.add((u >> 8) & 0xFF);
      }
      final encoded = base64Encode(bytes);
      final List<String> args;
      if (elevate) {
        // 外层普通权限 PowerShell：Start-Process -Verb RunAs 触发 UAC 弹窗，
        // -Wait 等待提权进程结束；-WindowStyle Hidden 隐藏 PowerShell 窗口
        args = [
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-Command',
          "Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden "
          "-ArgumentList @('-NoProfile','-EncodedCommand','$encoded')",
        ];
      } else {
        // 已提权进程：直接执行，无 UAC
        args = [
          '-NoProfile',
          '-WindowStyle',
          'Hidden',
          '-EncodedCommand',
          encoded,
        ];
      }
      final r = await Process.run('powershell.exe', args);
      // UAC 被取消时 exitCode 非 0 且无结果文件
      final out = File(outFile).existsSync()
          ? File(outFile).readAsStringSync().trim()
          : '';
      if (out.startsWith('ok')) return true;
      AppLog.w('autologin',
          '自动登录配置失败: exit=${r.exitCode} stderr=${r.stderr.toString().trim()} $out');
      return false;
    } catch (e) {
      AppLog.w('autologin', '自动登录配置异常', e);
      return false;
    }
  }
}
