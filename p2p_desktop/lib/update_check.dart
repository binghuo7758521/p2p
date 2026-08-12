import 'dart:convert';
import 'dart:io';

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

/// 向服务器检查电脑端是否有新版本（无网络/服务器异常时返回 null）
Future<UpdateInfo?> checkDesktopUpdate() async {
  final uri = Uri.parse(
      '$defaultServerUrl/update-check?platform=desktop&version=$appVersion');
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

/// 打开系统默认浏览器下载升级包
void openDownloadUrl(String relativeUrl) {
  final url = '$defaultServerUrl$relativeUrl';
  AppLog.i('update', '打开下载地址: $url');
  try {
    Process.start('explorer.exe', [url]);
  } catch (e) {
    AppLog.e('update', '打开下载地址失败', e);
  }
}
