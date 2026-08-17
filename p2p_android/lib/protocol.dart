/// 与电脑端浏览器版 (index.html) 完全兼容的 P2P 数据通道协议
library;

import 'dart:convert';

/// 文件分块大小（与电脑端一致）。
/// 64KB → 256KB：每块固定开销（Dart↔native 调用、接收端回调、写盘调度）
/// 摊薄 4 倍，手机端消费上限从 ~20MB/s 提升到 40MB/s+；
/// 256KB 在 libwebrtc/Chromium 的 DataChannel 单消息上限内（实测可发）
const int kChunkSize = 262144;

/// 背压阈值：数据通道待发送缓冲超过该值后暂停发送
const int kBackpressureLimit = 8 * 1024 * 1024;

/// 控制消息类型白名单（用于区分 JSON 控制消息与二进制文件块）
const List<String> kKnownMsgTypes = [
  'file-list-result',
  'file-meta',
  'file-complete',
  'file-ack',
  'file-delete-result',
  'file:list',
  'file:download',
  'file:upload',
  'file:delete',
  'file:accept',
  'file:conflict',
  'file:conflict-resolve',
  'user:list',
  'user:list-result',
  'user:create-share',
  'user:remove-share',
  'user:update-share',
  'user:attach-share',
  'user:share-result',
  'user:share-updated',
  'user:kick',
  'user:kick-result',
  'user:remove',
  'user:remove-result',
  // 电脑端已有其他管理员时：更换管理员申请结果（配对连接用户可申请）
  'user:claim-result',
  // 管理员远程生成/撤销激活码（v5.4+）
  'user:create-code',
  'user:revoke-code',
  // 远程电源控制（v5.9）：shutdown/reboot/cancel
  'user:power',
  'user:power-result',
  // 远程自动登录设置（v5.13）：status/enable/disable（重启后免输密码）
  'user:auto-login',
  'user:auto-login-result',
  'user:code-result',
  // 连接密码（v5.4+，数据通道内校验，服务器不接触密码）
  'auth:verify',
  'auth:ok',
  'auth:denied',
  'auth:change-pwd',
  'auth:pwd-result',
  'admin:pwd-reset',
];

/// 解析后的控制消息
class ControlMessage {
  final String type;
  final Map<String, dynamic> data;

  const ControlMessage(this.type, this.data);

  factory ControlMessage.fromJson(Map<String, dynamic> json) =>
      ControlMessage(json['type'] as String, json);
}

/// 从收到的原始数据（String 或二进制 `List<int>`）中尝试解析控制消息。
///
/// 兼容性说明：simple-peer 在电脑端会把字符串转为 Buffer，
/// 因此二进制数据也可能包含 JSON；通过首字符预筛 + type 白名单判断。
/// 返回 null 表示该数据是文件二进制块。
ControlMessage? tryParseControlMessage(dynamic data) {
  if (data is String) {
    return _parseJson(data);
  }
  if (data is List<int> && data.isNotEmpty) {
    if (data[0] == 0x7b /* { */ || data[0] == 0x5b /* [ */) {
      return _parseJson(utf8.decode(data, allowMalformed: true));
    }
  }
  return null;
}

ControlMessage? _parseJson(String text) {
  try {
    final json = jsonDecode(text);
    if (json is Map<String, dynamic> &&
        json['type'] is String &&
        kKnownMsgTypes.contains(json['type'])) {
      return ControlMessage.fromJson(json);
    }
  } catch (_) {
    // 非 JSON，视为文件数据
  }
  return null;
}

/// 格式化文件大小（与电脑端一致）
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
