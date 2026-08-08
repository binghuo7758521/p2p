import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
      if (!await f.exists()) return false;
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, dynamic>) {
        token = json['token']?.toString();
        phone = json['phone']?.toString();
        return token != null && token!.isNotEmpty;
      }
    } catch (_) {
      // 读取失败视为未登录
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
    } catch (_) {
      // 保存失败不影响本次会话
    }
  }

  /// 退出登录：清除本地 token
  Future<void> clear() async {
    token = null;
    phone = null;
    try {
      final f = await _authFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _post(
      String server, String path, Map<String, dynamic> body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse('$server$path'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  /// 发送短信验证码。
  /// 开发模式（服务器 SMS_DEV=1）返回 devCode 可直接显示，生产模式返回 null。
  Future<String?> sendSms(String server, String phone) async {
    final r = await _post(server, '/api/sms/send', {'phone': phone});
    if (r['ok'] != true) {
      throw AuthException(r['error']?.toString() ?? '发送失败，请稍后再试');
    }
    return r['devCode']?.toString();
  }

  /// 注册（需短信验证码），成功返回 token
  Future<String> register(
      String server, String phone, String code, String password) async {
    final r = await _post(server, '/api/register',
        {'phone': phone, 'code': code, 'password': password});
    if (r['ok'] != true) {
      throw AuthException(r['error']?.toString() ?? '注册失败，请稍后再试');
    }
    return r['token']?.toString() ?? '';
  }

  /// 登录，成功返回 token
  Future<String> login(String server, String phone, String password) async {
    final r = await _post(
        server, '/api/login', {'phone': phone, 'password': password});
    if (r['ok'] != true) {
      throw AuthException(r['error']?.toString() ?? '登录失败，请稍后再试');
    }
    return r['token']?.toString() ?? '';
  }
}

class AuthException implements Exception {
  final String message;

  AuthException(this.message);

  @override
  String toString() => message;
}
