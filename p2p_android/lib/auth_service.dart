import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 手机用户认证服务：短信验证码注册 / 登录 / Token 持久化
class AuthService {
  static final AuthService instance = AuthService._();

  AuthService._();

  String? token;
  String? phone;

  Future<File> _authFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/auth_info.json');
  }

  /// 读取本地登录状态（App 启动时调用）
  Future<bool> load() async {
    try {
      final f = await _authFile();
      if (!await f.exists()) {
        AppLog.i('auth', '未找到本地登录记录，进入未登录状态');
        return false;
      }
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, dynamic>) {
        token = json['token']?.toString();
        phone = json['phone']?.toString();
        final ok = token != null && token!.isNotEmpty;
        AppLog.i('auth', '读取本地登录记录: 手机号=$phone, 状态=${ok ? '已登录' : '无效'}, token长度=${token?.length ?? 0}');
        return ok;
      }
      AppLog.w('auth', '登录记录文件格式异常，视为未登录');
    } catch (e) {
      AppLog.e('auth', '读取登录记录失败', e);
    }
    return false;
  }

  /// 保存登录状态
  Future<void> save(String token, String phone) async {
    this.token = token;
    this.phone = phone;
    try {
      final f = await _authFile();
      await f.writeAsString(jsonEncode({'token': token, 'phone': phone}));
      AppLog.i('auth', '登录状态已保存: 手机号=$phone');
    } catch (e) {
      AppLog.e('auth', '保存登录状态失败（不影响本次会话）', e);
    }
  }

  /// 退出登录：清除本地 token
  Future<void> clear() async {
    AppLog.i('auth', '退出登录: 手机号=$phone');
    token = null;
    phone = null;
    try {
      final f = await _authFile();
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.e('auth', '清除登录记录失败', e);
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
        AppLog.w('auth', 'API非200响应: $path 状态码=${res.statusCode} 响应=${_truncate(text)}');
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

  /// 发送短信验证码。
  /// 开发模式（服务器 SMS_DEV=1）返回 devCode 可直接显示，生产模式返回 null。
  Future<String?> sendSms(String server, String phone) async {
    AppLog.i('auth', '请求发送验证码: 手机号=$phone');
    final r = await _post(server, '/api/sms/send', {'phone': phone});
    if (r['ok'] != true) {
      AppLog.w('auth', '发送验证码失败: ${r['error']}');
      throw AuthException(r['error']?.toString() ?? '发送失败，请稍后再试');
    }
    final dev = r['devCode']?.toString();
    AppLog.i('auth', '验证码发送成功${dev != null ? '（开发模式验证码=$dev）' : ''}');
    return dev;
  }

  /// 注册（需短信验证码），成功返回 token
  Future<String> register(
      String server, String phone, String code, String password) async {
    AppLog.i('auth', '发起注册: 手机号=$phone 验证码=${code.length}位');
    final r = await _post(server, '/api/register',
        {'phone': phone, 'code': code, 'password': password});
    if (r['ok'] != true) {
      AppLog.w('auth', '注册失败: ${r['error']}');
      throw AuthException(r['error']?.toString() ?? '注册失败，请稍后再试');
    }
    final t = r['token']?.toString() ?? '';
    AppLog.i('auth', '注册成功: 手机号=$phone token长度=${t.length}');
    return t;
  }

  /// 登录，成功返回 token
  Future<String> login(String server, String phone, String password) async {
    AppLog.i('auth', '发起登录: 手机号=$phone');
    final r = await _post(
        server, '/api/login', {'phone': phone, 'password': password});
    if (r['ok'] != true) {
      AppLog.w('auth', '登录失败: ${r['error']}');
      throw AuthException(r['error']?.toString() ?? '登录失败，请稍后再试');
    }
    final t = r['token']?.toString() ?? '';
    AppLog.i('auth', '登录成功: 手机号=$phone token长度=${t.length}');
    return t;
  }
  /// 重置密码（需短信验证码核验），成功返回 true
  Future<bool> resetPassword(
      String server, String phone, String code, String password) async {
    AppLog.i('auth', '发起重置密码: 手机号=$phone');
    final r = await _post(server, '/api/reset-password',
        {'phone': phone, 'code': code, 'password': password});
    if (r['ok'] != true) {
      AppLog.w('auth', '重置密码失败: ${r['error']}');
      throw AuthException(r['error']?.toString() ?? '重置失败，请稍后再试');
    }
    AppLog.i('auth', '重置密码成功: 手机号=$phone');
    return true;
  }
}

class AuthException implements Exception {
  final String message;

  AuthException(this.message);

  @override
  String toString() => message;
}
