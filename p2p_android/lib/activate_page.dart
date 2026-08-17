import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'activate_scan_page.dart';
import 'app_controller.dart';
import 'app_log.dart';
import 'auth_service.dart';
import 'home_page.dart';
import 'update_check.dart';
import 'version.dart';

/// 激活码格式：8 位大写字母/数字（与电脑端生成规则一致）
final RegExp kActCodeRegExp = RegExp(r'^[A-Z0-9]{8}$');

/// 激活页（v5.4+ 去手机号）：凭电脑端生成的激活码激活本设备。
/// v5.16+ 身份二态化：激活码均为管理员码，激活后直接成为该电脑管理员
/// （无需电脑端弹窗确认；已有管理员时由电脑端弹窗确认是否更换）
/// - 激活码 24 小时内有效、一次性使用；服务器不存任何个人信息
class ActivatePage extends StatefulWidget {
  final AppController controller;

  const ActivatePage({super.key, required this.controller});

  @override
  State<ActivatePage> createState() => _ActivatePageState();
}

class _ActivatePageState extends State<ActivatePage> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;

  /// 激活目标服务器：默认内置公网服务器；扫码二维码内嵌服务器时覆盖
  String _server = defaultServerUrl;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  void _showMsg(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  /// 激活：POST /api/activate 换取 {配对码, 类型, 设备令牌}，
  /// 成功后保存本地激活态并进入主页（自动连接返回的配对码）
  Future<void> _activate() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (!kActCodeRegExp.hasMatch(code)) {
      _showMsg('请输入正确的 8 位激活码', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      // v5.17+ 激活前即时校验（覆盖手输路径）；查询失败不阻塞，由服务器兑底
      final valid =
          await AuthService.instance.checkActCodeValid(_server, code);
      if (!mounted) return;
      if (!valid) {
        setState(() => _busy = false);
        _showMsg('激活码已失效（已被使用），请重新获取', error: true);
        return;
      }
      final result = await AuthService.instance
          .activate(_server, code, widget.controller.deviceId);
      await AuthService.instance.save(
        deviceToken: result.deviceToken,
        pairCode: result.pairCode,
        type: result.type,
        activationCode: code,
      );
      AppLog.i('app', '激活成功，进入主页');
      if (!mounted) return;
      _showMsg('激活成功，你已是本电脑管理员');
      _enterApp(result.pairCode);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final msg = e.toString();
      // v5.6+ 强制升级：旧版被服务器拒绝激活，弹不可跳过的升级窗
      if (msg == 'APP_VERSION_REQUIRED') {
        AppLog.i('auth', '激活被服务器拒绝（版本过低），引导强制升级');
        unawaited(handleVersionRequired(context));
        return;
      }
      _showMsg(msg, error: true);
    }
  }

  /// 进入主页面（激活后自动连接该电脑；主页内提供连接入口）
  void _enterApp(String pairCode) {
    final c = widget.controller;
    final code = pairCode.trim().toUpperCase();
    if (code.isNotEmpty) {
      // 激活即自动直连对应电脑（失败时主页显示重连视图）
      c.autoMode = true;
      unawaited(c.connect(_server, code));
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => HomePage(controller: c),
    ));
  }

  /// 扫码读取电脑端展示的激活码（二维码内容 `p2p-act:<server>|<码>`，
  /// 内含服务器地址时优先发往该服务器）或共享码（`p2p:<server>|<配对码>|<共享码>`）
  /// v5.17+ 二次扫描即时校验：已使用的码提示失效，不填入
  /// v5.18+ 共享码：自动激活共享访客并连接该共享
  Future<void> _scanCode() async {
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(builder: (_) => const ActivateScanPage()),
    );
    if (!mounted || result == null) return;
    if (result.kind == 'share') {
      final code = result.pairCode ?? '';
      final token = result.shareToken ?? '';
      if (code.isEmpty || token.isEmpty) return;
      _joinAsGuest(result.server ?? _server, code, token);
      return;
    }
    final code = result.code ?? '';
    if (code.isEmpty) return;
    final valid = await AuthService.instance
        .checkActCodeValid(result.server ?? _server, code);
    if (!mounted) return;
    if (!valid) {
      _showMsg('激活码已失效（已被使用），请重新获取', error: true);
      return;
    }
    setState(() {
      _codeCtrl.text = code;
      if (result.server != null && result.server!.isNotEmpty) {
        _server = result.server!;
      }
    });
    _showMsg('已识别激活码，点击「激活」完成激活');
  }

  /// v5.18+ 共享码访客流程：直接连接该共享，服务器自动激活访客
  /// （client:join 签发访客令牌）并绑定共享链接（join-relations），
  /// 连接成功后 client:joined 携带令牌，由 AppController 保存访客身份
  Future<void> _joinAsGuest(
      String server, String pairCode, String shareToken) async {
    setState(() => _busy = true);
    final c = widget.controller;
    c.autoMode = true;
    unawaited(c.connect(server, pairCode, shareToken: shareToken));
    _showMsg('已识别共享码，正在作为共享访客加入…');
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => HomePage(controller: c),
    ));
  }

  /// 从剪贴板粘贴激活码
  /// v5.17+ 粘贴后即时校验：已使用的码提示失效，不填入
  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim().toUpperCase() ?? '';
    if (!mounted) return;
    if (kActCodeRegExp.hasMatch(text)) {
      final valid =
          await AuthService.instance.checkActCodeValid(_server, text);
      if (!mounted) return;
      if (!valid) {
        _showMsg('激活码已失效（已被使用），请重新获取', error: true);
        return;
      }
      setState(() => _codeCtrl.text = text);
    } else {
      _showMsg('剪贴板中没有有效的 8 位激活码', error: true);
    }
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
                  Text('无限大盘 v$appVersion',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('凭电脑端激活码激活后使用 · 无手机号注册',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 24),

                  // 激活码输入
                  TextField(
                    controller: _codeCtrl,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.characters,
                    maxLength: 8,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[A-Za-z0-9]')),
                      UpperCaseTextFormatter(),
                    ],
                    decoration: const InputDecoration(
                      labelText: '激活码',
                      hintText: '8 位大写字母/数字',
                      prefixIcon: Icon(Icons.vpn_key_outlined),
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 扫码 / 粘贴
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _scanCode,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('扫码加入'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _pasteCode,
                          icon: const Icon(Icons.content_paste),
                          label: const Text('粘贴'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // 激活按钮
                  FilledButton.icon(
                    onPressed: _busy ? null : _activate,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.vpn_key),
                    label: Text(_busy ? '激活中...' : '激 活'),
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
                        Text('激活说明',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        const Text(
                          '1. 扫码电脑端展示的激活码成为管理员\n'
                          '2. 或扫共享二维码，作为共享访客直接加入\n'
                          '3. 激活码 24 小时内有效，使用一次后作废\n'
                          '4. 激活后自动连接电脑，无需手动配对\n'
                          '5. 共享访客仅可访问被分享的文件夹',
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

/// 输入自动转大写
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}
