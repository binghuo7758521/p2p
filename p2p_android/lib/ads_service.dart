import 'dart:convert';
import 'dart:io';

import 'app_log.dart';
import 'update_check.dart' show defaultServerUrl;

/// 广告位配置（v5.46+）：服务器管理后台 /api/admin/ads 配置，
/// 手机端通过公开接口 /api/ads 拉取；图片/链接为可选项
class AdInfo {
  /// 图片地址（可选，http(s)://）
  final String imageUrl;

  /// 标题（启用时必填，≤50 字）
  final String title;

  /// 描述（可选，≤200 字）
  final String message;

  /// 链接地址（可选，点击广告时打开）
  final String linkUrl;

  /// 投放期开始日期（可选，YYYY-MM-DD；空=不限）
  final String startDate;

  /// 投放期结束日期（可选，YYYY-MM-DD；空=不限）
  final String endDate;

  const AdInfo({
    required this.imageUrl,
    required this.title,
    required this.message,
    required this.linkUrl,
    required this.startDate,
    required this.endDate,
  });

  factory AdInfo.fromJson(Map<String, dynamic> json) => AdInfo(
        imageUrl: json['imageUrl']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        message: json['message']?.toString() ?? '',
        linkUrl: json['linkUrl']?.toString() ?? '',
        startDate: json['startDate']?.toString() ?? '',
        endDate: json['endDate']?.toString() ?? '',
      );

  bool get hasImage => imageUrl.isNotEmpty;

  bool get hasLink => linkUrl.isNotEmpty;

  /// 当前时间是否在投放期内（v5.47+）：YYYY-MM-DD 零填充格式
  /// 字典序=时间序，直接字符串比较；日期字段留空表示该侧不限
  bool isInSchedule(DateTime now) {
    final ymd = '${now.year.toString().padLeft(4, '0')}'
        '-${now.month.toString().padLeft(2, '0')}'
        '-${now.day.toString().padLeft(2, '0')}';
    if (startDate.isNotEmpty && ymd.compareTo(startDate) < 0) return false;
    if (endDate.isNotEmpty && ymd.compareTo(endDate) > 0) return false;
    return true;
  }
}

/// 拉取广告位配置（网络异常/未启用/无广告时返回 null）
Future<AdInfo?> fetchAd() async {
  final uri = Uri.parse('$defaultServerUrl/api/ads');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode != 200) return null;
    final body = await resp.transform(utf8.decoder).join();
    final data = jsonDecode(body) as Map<String, dynamic>;
    final ad = data['ad'];
    if (ad is! Map) return null;
    return AdInfo.fromJson(Map<String, dynamic>.from(ad));
  } catch (e) {
    AppLog.w('ads', '广告拉取失败（忽略）', e);
    return null;
  } finally {
    client.close();
  }
}
