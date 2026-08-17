import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'version.dart';

/// 升级检查结果
class UpdateInfo {
  final String latest; // 服务器最新版本
  final bool needUpdate; // 是否需要升级
  final bool force; // v5.6+ 服务器强制升级标记（旧版必须升级才能使用）
  final String? url; // 升级包下载地址（相对路径）
  final String notes; // 更新说明
  final String? md5; // 升级包 MD5（v5.22+ 下载后完整性校验）

  const UpdateInfo({
    required this.latest,
    required this.needUpdate,
    this.force = false,
    this.url,
    this.notes = '',
    this.md5,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        latest: json['latest']?.toString() ?? '',
        needUpdate: json['needUpdate'] == true,
        force: json['force'] == true,
        url: json['url']?.toString(),
        notes: json['notes']?.toString() ?? '',
        md5: json['md5']?.toString(),
      );
}

/// 默认升级服务器（与连接服务器一致：公网服务器）
const String defaultServerUrl = 'http://182.92.157.93:3000';

/// 向服务器检查手机端是否有新版本（无网络/服务器异常时返回 null）
Future<UpdateInfo?> checkAndroidUpdate() async {
  final uri = Uri.parse(
      '$defaultServerUrl/update-check?platform=android&version=$appVersion');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode != 200) return null;
    final body = await resp.transform(utf8.decoder).join();
    final info =
        UpdateInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    AppLog.i('update', '检查升级: 当前 v$appVersion, 最新 ${info.latest}, '
        '需升级=${info.needUpdate}');
    return info;
  } catch (e) {
    AppLog.w('update', '升级检查失败（忽略）', e);
    return null;
  } finally {
    client.close();
  }
}

/// 升级包安装结果（main.dart 据此提示用户）
enum InstallResult { installed, needPermission, cancelled, failed }

/// 原生安装通道（MainActivity p2p/install）
const MethodChannel _installChannel = MethodChannel('p2p/install');

/// App 内下载升级包并拉起系统安装器（v4.9+）
/// 升级包存于对象存储（OSS 默认公网域名禁止浏览器匿名下载 .apk），
/// 改为 App 内下载：跟随 302 到对象存储直链，保存为 APK 后调用安装器
/// v5.2：Android 8+ 未授权"安装未知应用"时引导用户去系统设置开启，
/// 开启后自动继续安装；安装器拉起失败不再静默，返回 failed 供 UI 提示
/// v5.22：下载完成后流式 MD5 校验（服务器提供校验值时），防止 OSS
/// 漏同步导致静默装成旧版本
Future<InstallResult> downloadAndInstallApk(
  String relativeUrl, {
  String? expectedMd5,
  BuildContext? context,
  void Function(int received, int total)? onProgress,
}) async {
  final url = '$defaultServerUrl$relativeUrl';
  AppLog.i('update', '开始下载升级包: $url');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      AppLog.e('update', '下载失败: HTTP ${resp.statusCode}');
      return InstallResult.failed;
    }
    final total =
        int.tryParse(resp.headers.value('content-length') ?? '') ?? 0;
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/app-release.apk');
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
    client.close();
    AppLog.i('update', '升级包下载完成: ${file.path} ($received 字节)');
    // v5.22：MD5 完整性校验，不匹配直接失败（旧包安装后版本不变会反复弹窗）
    final expected = expectedMd5?.trim().toLowerCase();
    if (expected != null && expected.isNotEmpty) {
      final digest = await _fileMd5(file);
      if (digest != expected) {
        AppLog.e('update', 'MD5 校验失败: 期望 $expected 实际 $digest');
        return InstallResult.failed;
      }
      AppLog.i('update', 'MD5 校验通过: $digest');
    }
    if (context != null && !context.mounted) return InstallResult.cancelled;
    return _installWithGuide(context, file.path);
  } catch (e) {
    AppLog.e('update', '升级包下载异常', e);
    return InstallResult.failed;
  } finally {
    client.close(force: true);
  }
}

/// 流式计算文件 MD5（大文件避免整包读入内存）
Future<String> _fileMd5(File file) async {
  final digestSink = AccumulatorSink<Digest>();
  final input = ByteConversionSink.withCallback(
      (data) => digestSink.add(md5.convert(data)));
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return digestSink.events.single.toString();
}

/// 拉起系统安装器；返回安装结果（needPermission 表示需先开启授权）
/// v5.7 修复：PlatformException 不再被误判为“已拉起”，统一返回 failed
Future<InstallResult> _invokeInstall(String path) async {
  try {
    final r = await _installChannel
        .invokeMethod('installApk', {'path': path}) as Map?;
    return r?['needPermission'] == true
        ? InstallResult.needPermission
        : InstallResult.installed;
  } on PlatformException catch (e) {
    AppLog.e('update', '拉起安装器失败: ${e.code} ${e.message}');
    return InstallResult.failed;
  }
}

/// 安装主流程：先尝试拉起安装器，未授权时引导开启后轮询自动继续
Future<InstallResult> _installWithGuide(BuildContext? context, String path) async {
  final first = await _invokeInstall(path);
  if (first != InstallResult.needPermission) return first;
  AppLog.i('update', '未授权安装未知应用，引导用户开启');
  if (context == null) return InstallResult.failed;
  if (!context.mounted) return InstallResult.cancelled;
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.security, color: Colors.orange),
      title: const Text('需要安装权限'),
      content: const Text(
          '系统要求先允许 无限大盘 安装未知来源应用，才能安装升级包。\n\n'
          '点击"去开启"后将跳转系统设置，开启后会自动继续安装。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去开启')),
      ],
    ),
  );
  if (go != true || !context.mounted) return InstallResult.cancelled;
  try {
    await _installChannel.invokeMethod('openInstallSettings');
  } catch (e) {
    AppLog.w('update', '跳转安装权限设置失败', e);
  }
  // 轮询等待用户开启授权（最多 60 秒），开启后自动拉起安装器
  for (var i = 0; i < 120; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    if (!context.mounted) return InstallResult.cancelled;
    try {
      final ok = await _installChannel.invokeMethod('canInstallUnknown') as bool?;
      if (ok == true) {
        AppLog.i('update', '安装权限已开启，继续安装');
        return _invokeInstall(path);
      }
    } catch (e) {
      AppLog.w('update', '查询安装权限失败', e);
    }
  }
  AppLog.w('update', '等待安装权限开启超时');
  return InstallResult.cancelled;
}

/// v5.6+ 强制升级弹窗：服务器要求旧版必须升级才能继续使用。
/// 无“稍后”选项，仅“立即更新”或“退出应用”；返回键关闭或下载失败后自动重弹。
Future<void> showForcedUpdateDialog(BuildContext context, UpdateInfo info) async {
  while (context.mounted) {
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: Text('必须升级到 v${info.latest}'),
        content: Text(
          '当前版本 v$appVersion 已停止服务，升级后才能继续使用。\n\n'
          '${info.notes}\n\n'
          '下载后将通过系统安装器安装，请确认允许安装未知来源应用',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('exit'),
            child: const Text('退出应用'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop('download'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('立即更新'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (action == 'exit') {
      // 退出应用；再次打开仍会弹强制升级窗
      SystemNavigator.pop();
      return;
    }
    // 'download' 或返回键关闭（null）：进入下载流程，失败则循环重弹
    if (info.url == null) continue;
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('准备下载…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('下载升级包'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (ctx, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (p == null)
                const CircularProgressIndicator()
              else
                LinearProgressIndicator(value: p),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (ctx, s, _) => Text(s),
              ),
            ],
          ),
        ),
      ),
    );
    final result = await downloadAndInstallApk(
      info.url!,
      expectedMd5: info.md5,
      context: context,
      onProgress: (received, total) {
        progress.value = total > 0 ? received / total : null;
        status.value = total > 0
            ? '已下载 ${(received / 1048576).toStringAsFixed(1)} / '
                '${(total / 1048576).toStringAsFixed(1)} MB'
            : '已下载 $received 字节';
      },
    );
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关闭进度对话框
    if (result == InstallResult.installed) {
      // 已拉起系统安装器：用户完成安装后打开新版即可
      return;
    }
    final msg = switch (result) {
      InstallResult.needPermission => '请到系统设置开启安装权限后重试升级',
      InstallResult.cancelled => '升级未完成，必须升级后才能继续使用',
      InstallResult.failed => '下载或安装失败，请重新尝试升级',
      _ => '',
    };
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ));
    }
    // 失败/取消：继续循环重弹强制升级窗
  }
}

/// v5.6+：收到服务器 APP_VERSION_REQUIRED 拒绝时，拉取升级信息并弹强制升级窗
Future<void> handleVersionRequired(BuildContext context) async {
  final info = await checkAndroidUpdate();
  if (!context.mounted) return;
  await showForcedUpdateDialog(
    context,
    info ??
        const UpdateInfo(
          latest: '',
          needUpdate: true,
          force: true,
          url: null,
          notes: '当前版本已停止服务，请升级到最新版本后重试',
        ),
  );
}
