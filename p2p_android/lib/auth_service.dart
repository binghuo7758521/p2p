import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'version.dart';

/// 激活结果（POST /api/activate 返回值）
class ActivateResult {
  final String pairCode; // 该电脑的配对码（激活后免输码连接）
  final String type; // admin=管理员码（v5.16+ 仅此一种）
  final String deviceToken; // 设备令牌（拉取共享/免配对码连接鉴权）

  const ActivateResult({
    required this.pairCode,
    required this.type,
    required this.deviceToken,
  });
}

/// 手机端激活服务（v5.4+ 去手机号）：凭电脑端激活码换取设备令牌。
/// - 服务器不存任何个人信息，仅存临时凭证（设备令牌）
/// - 激活码由电脑端管理页生成，24h 有效、一次性使用
class AuthService {
  static final AuthService instance = AuthService._();

  AuthService._();

  /// 激活后服务器签发的设备令牌（Bearer 鉴权 / 共享拉取）
  String? deviceToken;

  /// 激活码类型：admin=管理员码（v5.16+ 仅此一种）
  String? type;

  /// 激活时使用的激活码（连接时上报电脑端识别身份）
  String? activationCode;

  /// 共享访客归属的共享码（v5.18+：扫共享码自动激活的访客身份）
  String? shareToken;

  /// 激活时返回的电脑配对码（激活后自动连接，免手动输入）
  String? pairCode;

  /// 是否已激活（本地有有效令牌）
  bool get activated => deviceToken != null && deviceToken!.isNotEmpty;

  Future<File> _authFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/auth_info.json');
  }

  /// 读取本地激活状态（App 启动时调用）
  Future<bool> load() async {
    try {
      final f = await _authFile();
      if (!await f.exists()) {
        AppLog.i('auth', '未找到本地激活记录，进入未激活状态');
        return false;
      }
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, dynamic>) {
        deviceToken = json['deviceToken']?.toString();
        pairCode = json['pairCode']?.toString();
        type = json['type']?.toString();
        activationCode = json['activationCode']?.toString();
        shareToken = json['shareToken']?.toString();
        final ok = activated;
        AppLog.i('auth',
            '读取本地激活记录: 类型=${type ?? '未知'} 状态=${ok ? '已激活' : '无效'}');
        return ok;
      }
      AppLog.w('auth', '激活记录文件格式异常，视为未激活');
    } catch (e) {
      AppLog.e('auth', '读取激活记录失败', e);
    }
    return false;
  }

  /// 保存激活状态（[activationCode] 为手机端输入的原激活码，连接时上报电脑端；
  /// [shareToken] 为共享访客的归属共享码，管理员激活时为空）
  Future<void> save({
    required String deviceToken,
    required String pairCode,
    required String type,
    String activationCode = '',
    String shareToken = '',
  }) async {
    this.deviceToken = deviceToken;
    this.pairCode = pairCode;
    this.type = type;
    this.activationCode = activationCode;
    this.shareToken = shareToken;
    try {
      final f = await _authFile();
      await f.writeAsString(jsonEncode({
        'deviceToken': deviceToken,
        'pairCode': pairCode,
        'type': type,
        'activationCode': activationCode,
        'shareToken': shareToken,
      }));
      AppLog.i('auth', '激活状态已保存: 类型=$type');
    } catch (e) {
      AppLog.e('auth', '保存激活状态失败（不影响本次会话）', e);
    }
  }

  /// 退出登录：清除本地激活记录
  Future<void> clear() async {
    AppLog.i('auth', '退出激活状态: 类型=$type');
    deviceToken = null;
    pairCode = null;
    type = null;
    activationCode = null;
    shareToken = null;
    try {
      final f = await _authFile();
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.e('auth', '清除激活记录失败', e);
    }
  }

  Future<Map<String, dynamic>> _post(
      String server, String path, Map<String, dynamic> body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final startMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final req = await client.postUrl(Uri.parse('$server$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final cost = DateTime.now().millisecondsSinceEpoch - startMs;
      AppLog.i('auth', 'API请求: $path => HTTP ${res.statusCode} 耗时${cost}ms');
      if (res.statusCode != 200) {
        AppLog.w('auth',
            'API非200响应: $path 状态码=${res.statusCode} 响应=${_truncate(text)}');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      AppLog.e('auth', 'API请求异常: $path', e);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 截断响应文本（避免超长响应刷屏）
  static String _truncate(String s, [int max = 300]) =>
      s.length <= max ? s : '${s.substring(0, max)}…(${s.length}字符)';

  /// 查询激活码是否仍有效（v5.17+ 扫码/粘贴/激活前即时校验，二次扫描提示失效）
  /// 返回 true=可用；false=已使用/已失效；
  /// 网络异常等查询失败时返回 true，交由激活接口兜底（兼容旧服务器）
  Future<bool> checkActCodeValid(String server, String code) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final req = await client
            .getUrl(Uri.parse('$server/api/activate-status?code=$code'));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          AppLog.w('auth', '激活码状态查询非200: ${res.statusCode}');
          return true;
        }
        final data = jsonDecode(text) as Map<String, dynamic>;
        final valid = data['ok'] == true && data['valid'] == true;
        AppLog.i('auth',
            '激活码状态查询: ${code.length}位 => ${valid ? '有效' : '失效'}');
        return valid;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      AppLog.w('auth', '激活码状态查询失败，交由激活接口兜底', e);
      return true;
    }
  }

  /// 激活：凭电脑端生成的激活码换取 {配对码, 类型, 设备令牌}。
  /// 激活成功后需调用 [save] 持久化本地激活状态。
  Future<ActivateResult> activate(
      String server, String code, String deviceId) async {
    AppLog.i('auth', '发起激活: 码=${code.length}位 deviceId=$deviceId');
    final r = await _post(server, '/api/activate', {
      'code': code,
      'deviceId': deviceId,
      // v5.6+：上报版本号，服务器拒绝旧版（APP_VERSION_REQUIRED）
      'version': appVersion,
    });
    if (r['ok'] != true) {
      AppLog.w('auth', '激活失败: ${r['error']}');
      throw AuthException(r['error']?.toString() ?? '激活失败，请稍后再试');
    }
    final result = ActivateResult(
      pairCode: r['pairCode']?.toString() ?? '',
      // v5.16+ 身份二态化：激活码均为管理员码，服务器恒返回 admin
      type: r['type']?.toString() ?? 'admin',
      deviceToken: r['deviceToken']?.toString() ?? '',
    );
    if (result.deviceToken.isEmpty || result.pairCode.isEmpty) {
      throw AuthException('服务器响应异常，请稍后再试');
    }
    AppLog.i('auth',
        '激活成功: 类型=${result.type} 配对码=${result.pairCode}');
    return result;
  }
}

class AuthException implements Exception {
  final String message;

  AuthException(this.message);

  @override
  String toString() => message;
}
