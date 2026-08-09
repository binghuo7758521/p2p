import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'auth_service.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'scan_page.dart';

/// 连接页：输入服务器地址与配对码
class ConnectPage extends StatefulWidget {
  final AppController controller;

  /// 是否在启动时自动连接上次配对的电脑（App 冷启动为 true，
  /// 手动断开返回时为 false，避免无限重连）
  final bool autoConnect;

  const ConnectPage({
    super.key,
    required this.controller,
    this.autoConnect = true,
  });

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _serverCtrl = TextEditingController(text: 'http://182.92.157.93:3000');
  final _codeCtrl = TextEditingController();
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) {
      // 冷启动自动直连：失败自动重试（电脑端未开/服务器重启都能自动恢复）
      widget.controller.autoMode = true;
      _loadSavedAndAutoConnect();
    }
  }

  /// 读取上次配对信息并自动连接（无需再次扫码/输入）
  Future<void> _loadSavedAndAutoConnect() async {
    final info = await widget.controller.loadPairInfo();
    if (!mounted || info == null) return;
    _serverCtrl.text = info.server;
    _codeCtrl.text = info.code.toUpperCase();
    await _connect();
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    // 手动/扫码连接：失败立即提示，不自动重试
    widget.controller.autoMode = false;
    final server = _serverCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    final code = _codeCtrl.text.trim().toUpperCase();
    if (server.isEmpty) {
      _showError('请输入服务器地址');
      return;
    }
    if (!kPairCodeRegExp.hasMatch(code)) {
      _showError('配对码为 10 位数字/字母');
      return;
    }
    setState(() => _submitted = true);
    await widget.controller.connect(server, code);
    if (!mounted) return;

    // 等待配对结果
    await _waitForPair();
  }

  /// 扫码配对：扫描电脑端二维码，自动填入服务器地址与配对码并连接
  Future<void> _scanPair() async {
    final result = await Navigator.of(context).push<ScanPairResult>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) return;
    _serverCtrl.text = result.server;
    _codeCtrl.text = result.code.toUpperCase();
    await _connect();
  }

  Future<void> _waitForPair() async {
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 300));
      final s = widget.controller.state;
      if (s == ConnectState.paired || s == ConnectState.peerConnected) {
        // 配对成功：保存信息，下次启动自动直连
        await widget.controller.savePairInfo(
          _serverCtrl.text.trim(),
          _codeCtrl.text.trim().toUpperCase(),
        );
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => HomePage(controller: widget.controller)),
        );
        return;
      }
      // 自动直连且电脑端暂未上线：直接进入主页面，
      // 主页显示“正在自动重连”，电脑端上线后自动恢复并刷新文件列表
      if (s == ConnectState.lost && widget.autoConnect) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => HomePage(controller: widget.controller)),
        );
        return;
      }
      if (s == ConnectState.error) {
        if (!mounted) return;
        setState(() => _submitted = false);
        return;
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 退出登录：清除本地 token 并返回登录页
  Future<void> _logout() async {
    widget.controller.dispose();
    await AuthService.instance.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final busy =
                      controller.state == ConnectState.connecting || _submitted;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: busy ? null : _logout,
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('退出登录'),
                        ),
                      ),
                      const Icon(Icons.swap_horiz_rounded,
                          size: 64, color: Color(0xFF38BDF8)),
                      const SizedBox(height: 12),
                      Text('P2P 文件助手',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('与电脑浏览器版互通',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: Colors.grey)),
                      const SizedBox(height: 32),

                      TextField(
                        controller: _serverCtrl,
                        enabled: !busy,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'http://182.92.157.93:3000',
                          prefixIcon: Icon(Icons.dns_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _codeCtrl,
                        enabled: !busy,
                        maxLength: 10,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: '配对码',
                          hintText: '10 位数字/字母',
                          prefixIcon: Icon(Icons.pin_outlined),
                          border: OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 扫码配对
                      OutlinedButton.icon(
                        onPressed: busy ? null : _scanPair,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('扫码配对'),
                      ),
                      const SizedBox(height: 12),

                      FilledButton.icon(
                        onPressed: busy ? null : _connect,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        icon: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.link),
                        label: Text(busy ? '正在连接...' : '连接电脑'),
                      ),

                      if (controller.state == ConnectState.error)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            controller.errorMessage ?? '连接失败',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.w500),
                          ),
                        ),

                      const SizedBox(height: 32),
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
                              '1. 电脑打开 P2P 软件（或浏览器打开服务器地址）\n'
                              '2. 选择共享目录，界面显示 10 位配对码\n'
                              '3. 手机扫码自动填入，或手动输入配对码\n'
                              '4. 默认连接公网服务器，同一网络可用局域网 IP',
                              style: TextStyle(fontSize: 13, height: 1.6),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
