import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'auth_service.dart';
import 'update_check.dart';

/// 忘记密码页：手机号 + 短信验证码核验后重置密码
class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key, this.initialPhone});

  /// 从登录页带入的手机号（可选）
  final String? initialPhone;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _phoneCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwd2Ctrl = TextEditingController();

  bool _busy = false;
  bool _sending = false;
  int _countdown = 0; // 验证码发送倒计时
  Timer? _timer;

  /// 默认连接内置公网服务器，不在界面展示
  String get _server => defaultServerUrl;

  @override
  void initState() {
    super.initState();
    if (widget.initialPhone != null && widget.initialPhone!.isNotEmpty) {
      _phoneCtrl.text = widget.initialPhone!;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _pwdCtrl.dispose();
    _pwd2Ctrl.dispose();
    super.dispose();
  }

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

  /// 提交重置
  Future<void> _submit() async {
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
      await AuthService.instance.resetPassword(_server, phone, code, password);
      AppLog.i('auth', '密码重置成功，返回登录页');
      if (!mounted) return;
      _showMsg('密码重置成功，请用新密码登录');
      Navigator.of(context).pop(phone);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showMsg(e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('重置密码')),
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
                  const Icon(Icons.lock_reset,
                      size: 64, color: Color(0xFF38BDF8)),
                  const SizedBox(height: 12),
                  Text('忘记密码？',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('通过短信验证码验证身份后设置新密码',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 24),

                  // 手机号
                  TextField(
                    controller: _phoneCtrl,
                    enabled: !_busy,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly
                    ],
                    decoration: const InputDecoration(
                      labelText: '手机号',
                      hintText: '11 位手机号',
                      prefixIcon: Icon(Icons.phone_android),
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 验证码
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

                  // 新密码
                  TextField(
                    controller: _pwdCtrl,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '新密码（至少 6 位）',
                      prefixIcon: Icon(Icons.lock_outline),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 确认新密码
                  TextField(
                    controller: _pwd2Ctrl,
                    enabled: !_busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '确认新密码',
                      prefixIcon: Icon(Icons.lock_reset),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 提交按钮
                  FilledButton.icon(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_reset),
                    label: Text(_busy ? '提交中...' : '重置密码'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '重置成功后需使用新密码重新登录',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey),
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
