import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'auth_service.dart';
import 'connect_page.dart';

/// 登录 / 注册页：注册（短信验证码）后才能登录使用
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _serverCtrl = TextEditingController(text: 'http://182.92.157.93:3000');
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwd2Ctrl = TextEditingController();

  bool _isRegister = false; // false=登录, true=注册
  bool _busy = false;
  bool _sending = false;
  int _countdown = 0; // 验证码发送倒计时
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _serverCtrl.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _pwdCtrl.dispose();
    _pwd2Ctrl.dispose();
    super.dispose();
  }

  String get _server =>
      _serverCtrl.text.trim().replaceAll(RegExp(r'/$'), '');

  void _showMsg(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  /// 发送短信验证码（60 秒倒计时）
  Future<void> _sendSms() async {
    final phone = _phoneCtrl.text.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      _showMsg('请输入正确的 11 位手机号', error: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final devCode = await AuthService.instance.sendSms(_server, phone);
      if (!mounted) return;
      if (devCode != null) {
        _showMsg('开发模式验证码: $devCode（服务器未配置阿里云短信）');
      } else {
        _showMsg('验证码已发送，请注意查收短信');
      }
      setState(() {
        _countdown = 60;
        _sending = false;
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _countdown--;
          if (_countdown <= 0) t.cancel();
        });
      });
    } catch (e) {
      setState(() => _sending = false);
      _showMsg(e.toString(), error: true);
    }
  }

  /// 登录
  Future<void> _login() async {
    final phone = _phoneCtrl.text.trim();
    final password = _pwdCtrl.text;
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      _showMsg('请输入正确的 11 位手机号', error: true);
      return;
    }
    if (password.length < 6) {
      _showMsg('密码至少 6 位', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final token = await AuthService.instance.login(_server, phone, password);
      await AuthService.instance.save(token, phone);
      if (!mounted) return;
      _enterApp();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showMsg(e.toString(), error: true);
    }
  }

  /// 注册
  Future<void> _register() async {
    final phone = _phoneCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final password = _pwdCtrl.text;
    final password2 = _pwd2Ctrl.text;
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      _showMsg('请输入正确的 11 位手机号', error: true);
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showMsg('请输入 6 位短信验证码', error: true);
      return;
    }
    if (password.length < 6) {
      _showMsg('密码至少 6 位', error: true);
      return;
    }
    if (password != password2) {
      _showMsg('两次输入的密码不一致', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final token =
          await AuthService.instance.register(_server, phone, code, password);
      await AuthService.instance.save(token, phone);
      if (!mounted) return;
      _showMsg('注册成功，欢迎使用');
      _enterApp();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showMsg(e.toString(), error: true);
    }
  }

  /// 进入主流程（连接电脑）
  void _enterApp() {
    final controller = AppController();
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => ConnectPage(controller: controller),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.swap_horiz_rounded,
                      size: 64, color: Color(0xFF38BDF8)),
                  const SizedBox(height: 12),
                  Text('P2P 文件助手',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('注册后才能使用 · 短信验证码注册',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 24),

                  // 服务器地址
                  TextField(
                    controller: _serverCtrl,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'http://182.92.157.93:3000',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 登录 / 注册切换
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false, label: Text('登录'), icon: Icon(Icons.login)),
                      ButtonSegment(
                          value: true,
                          label: Text('注册'),
                          icon: Icon(Icons.person_add_alt_1)),
                    ],
                    selected: {_isRegister},
                    onSelectionChanged: _busy
                        ? null
                        : (s) => setState(() => _isRegister = s.first),
                  ),
                  const SizedBox(height: 20),

                  // 手机号
                  TextField(
                    controller: _phoneCtrl,
                    enabled: !_busy,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '手机号',
                      hintText: '11 位手机号',
                      prefixIcon: Icon(Icons.phone_android),
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 注册模式：验证码
                  if (_isRegister) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeCtrl,
                            enabled: !_busy,
                            keyboardType: TextInputType.number,
                            maxLength: 6,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly
                            ],
                            decoration: const InputDecoration(
                              labelText: '短信验证码',
                              hintText: '6 位数字',
                              prefixIcon: Icon(Icons.sms_outlined),
                              border: OutlineInputBorder(),
                              counterText: '',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          height: 56,
                          child: OutlinedButton(
                            onPressed: (_busy || _sending || _countdown > 0)
                                ? null
                                : _sendSms,
                            child: Text(_countdown > 0
                                ? '${_countdown}s 后重发'
                                : (_sending ? '发送中...' : '获取验证码')),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 密码
                  TextField(
                    controller: _pwdCtrl,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _isRegister ? '设置密码（至少 6 位）' : '密码',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: const OutlineInputBorder(),
                      suffixIcon: _isRegister
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.help_outline),
                              tooltip: '忘记密码请联系管理员',
                              onPressed: () => _showMsg(
                                  '密码暂不支持找回，请联系管理员重置'),
                            ),
                    ),
                  ),
                  if (_isRegister) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _pwd2Ctrl,
                      enabled: !_busy,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '确认密码',
                        prefixIcon: Icon(Icons.lock_reset),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),

                  // 提交按钮
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : (_isRegister ? _register : _login),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(_isRegister
                            ? Icons.person_add_alt_1
                            : Icons.login),
                    label: Text(_busy
                        ? (_isRegister ? '注册中...' : '登录中...')
                        : (_isRegister ? '注 册' : '登 录')),
                  ),

                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('使用说明',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        const Text(
                          '1. 首次使用请先「注册」：输入手机号获取短信验证码\n'
                          '2. 注册成功后自动登录，之后可直接「登录」\n'
                          '3. 登录后即可输入配对码连接电脑\n'
                          '4. 账号需管理员后台启用后方可登录',
                          style: TextStyle(fontSize: 13, height: 1.6),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
