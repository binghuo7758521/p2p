import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'usb_drives.dart';

/// U盘授权验证结果
class LicenseResult {
  /// 是否已授权（任一U盘ID在服务器白名单中）
  final bool licensed;

  /// 验证失败原因（服务器不可达等），null 表示正常完成了验证
  final String? error;

  /// 未授权时展示的购买方式（来自服务器配置）
  final String buyTitle;
  final String buyWechat;
  final String buyPhone;

  const LicenseResult({
    required this.licensed,
    this.error,
    this.buyTitle = '',
    this.buyWechat = '',
    this.buyPhone = '',
  });

  bool get reachable => error == null;
}

/// 启动授权验证：读取本机所有U盘卷序列号，请求服务器白名单校验。
/// - 服务器可达：返回授权判定 + 购买方式（未授权时）
/// - 服务器不可达（断网等）：licensed=false + error，调用方锁定并提示重试
Future<LicenseResult> verifyLicense(String serverUrl) async {
  final drives = listUsbDrives();
  final ids = drives.map((d) => d.serial).toList();
  AppLog.i('license', 'U盘授权验证: 检测到 ${drives.length} 个U盘 ${ids.join(', ')}');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client
        .postUrl(Uri.parse('$serverUrl/api/usb/verify'))
        .timeout(const Duration(seconds: 10));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'usbIds': ids}));
    final resp = await req.close().timeout(const Duration(seconds: 10));
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw HttpException('验证服务异常(HTTP ${resp.statusCode})');
    }
    final json = jsonDecode(body);
    if (json is! Map || json['ok'] != true) {
      throw const FormatException('验证服务响应异常');
    }
    final buy = json['buyInfo'] is Map ? json['buyInfo'] as Map : const {};
    AppLog.i('license',
        '授权验证完成: ${json['licensed'] == true ? '已授权' : '未授权'}');
    return LicenseResult(
      licensed: json['licensed'] == true,
      buyTitle: buy['title']?.toString() ?? '',
      buyWechat: buy['wechat']?.toString() ?? '',
      buyPhone: buy['phone']?.toString() ?? '',
    );
  } catch (e) {
    AppLog.w('license', '授权验证失败（服务器不可达或异常）: $e');
    return LicenseResult(licensed: false, error: '无法连接验证服务器，请联网后重试');
  } finally {
    client.close();
  }
}
