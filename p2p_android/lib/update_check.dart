import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'version.dart';

/// 升级检查结果
class UpdateInfo {
  final String latest; // 服务器最新版本
  final bool needUpdate; // 是否需要升级
  final String? url; // 升级包下载地址（相对路径）
  final String notes; // 更新说明

  const UpdateInfo({
    required this.latest,
    required this.needUpdate,
    this.url,
    this.notes = '',
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        latest: json['latest']?.toString() ?? '',
        needUpdate: json['needUpdate'] == true,
        url: json['url']?.toString(),
        notes: json['notes']?.toString() ?? '',
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
Future<InstallResult> downloadAndInstallApk(
  String relativeUrl, {
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
    await for (final chunk in resp) {
      received += chunk.length;
      sink.add(chunk);
      onProgress?.call(received, total);
    }
    await sink.close();
    client.close();
    AppLog.i('update', '升级包下载完成: ${file.path} ($received 字节)');
    if (context != null && !context.mounted) return InstallResult.cancelled;
    return _installWithGuide(context, file.path);
  } catch (e) {
    AppLog.e('update', '升级包下载异常', e);
    return InstallResult.failed;
  } finally {
    client.close(force: true);
  }
}

/// 拉起系统安装器；返回 true 表示需要用户先开启"安装未知应用"授权
Future<bool> _invokeInstall(String path) async {
  try {
    final r = await _installChannel
        .invokeMethod('installApk', {'path': path}) as Map?;
    return r?['needPermission'] == true;
  } on PlatformException catch (e) {
    AppLog.e('update', '拉起安装器失败: ${e.code} ${e.message}');
    return false;
  }
}

/// 安装主流程：先尝试拉起安装器，未授权时引导开启后轮询自动继续
Future<InstallResult> _installWithGuide(BuildContext? context, String path) async {
  final need = await _invokeInstall(path);
  if (!need) return InstallResult.installed;
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
          '系统要求先允许 P2P 文件助手安装未知来源应用，才能安装升级包。\n\n'
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
        final needAgain = await _invokeInstall(path);
        return needAgain ? InstallResult.failed : InstallResult.installed;
      }
    } catch (e) {
      AppLog.w('update', '查询安装权限失败', e);
    }
  }
  AppLog.w('update', '等待安装权限开启超时');
  return InstallResult.cancelled;
}
