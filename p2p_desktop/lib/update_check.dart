import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'version.dart';

/// 升级检查结果
class UpdateInfo {
  final String latest; // 服务器最新版本
  final bool needUpdate; // 是否需要升级
  final bool urgent; // v6.23+ 重要升级（服务器紧急线标记，立即弹窗提示）
  final bool force; // v6.24+ 版本不再支持（服务器下线线标记，强制升级）
  final String? url; // 升级包下载地址（相对路径）
  final String notes; // 更新说明
  final String? md5; // 升级包 MD5（静默升级完整性校验；null 时回退手动下载）

  const UpdateInfo({
    required this.latest,
    required this.needUpdate,
    this.urgent = false,
    this.force = false,
    this.url,
    this.notes = '',
    this.md5,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        latest: json['latest']?.toString() ?? '',
        needUpdate: json['needUpdate'] == true,
        urgent: json['urgent'] == true,
        force: json['force'] == true,
        url: json['url']?.toString(),
        notes: json['notes']?.toString() ?? '',
        md5: json['md5']?.toString(),
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
        '需升级=${info.needUpdate}, 强制=${info.force}, 重要=${info.urgent}');
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

/// 下载升级包到本地文件（带进度回调：已下载字节/总字节）
///
/// 失败时抛出异常，由调用方决定回退策略。
/// v6.17：连接后总下载超时 10 分钟，OSS 异常/网络卡死时避免进度条永久挂起
Future<void> downloadUpgradeZip(
  String relativeUrl,
  String targetPath,
  void Function(int received, int total)? onProgress,
) async {
  final uri = Uri.parse('$defaultServerUrl$relativeUrl');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  // 总超时：强制关闭连接会中断下载流并抛异常，由调用方回退手动下载
  final deadline = Timer(const Duration(minutes: 10), () {
    client.close(force: true);
  });
  try {
    final req = await client.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw HttpException('下载失败: HTTP ${resp.statusCode}', uri: uri);
    }
    final total = resp.contentLength;
    final sink = File(targetPath).openWrite();
    var received = 0;
    try {
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  } finally {
    deadline.cancel();
    client.close();
  }
}
