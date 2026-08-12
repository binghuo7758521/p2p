import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_log.dart';
import 'auth_service.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'scan_page.dart';
import 'update_check.dart';
import 'version.dart';

/// 连接页：输入配对码（服务器地址内置，不展示）
class ConnectPage extends StatefulWidget {
  final AppController controller;

  /// 是否在启动时自动连接上次配对的电脑（App 冷启动为 true，
  /// 手动断开返回时为 false，避免无限重连）
  final bool autoConnect;

  /// 初始服务器地址/配对码（扫码共享二维码跳转时预填）
  final String? initialServer;
  final String? initialCode;

  /// 连接时携带的共享码（扫码共享二维码时非空）
  final String? pendingShareToken;

  const ConnectPage({
    super.key,
    required this.controller,
    this.autoConnect = true,
    this.initialServer,
    this.initialCode,
    this.pendingShareToken,
  });

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  /// 当前使用的服务器地址（默认内置公网服务器，不展示）
  String _server = defaultServerUrl;
  final _codeCtrl = TextEditingController();
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialServer != null && widget.initialServer!.isNotEmpty) {
      _server = widget.initialServer!;
    }
    if (widget.initialCode != null && widget.initialCode!.isNotEmpty) {
      _codeCtrl.text = widget.initialCode!.toUpperCase();
    }
    if (widget.autoConnect) {
      // 冷启动自动直连：失败自动重试（电脑端未开/服务器重启都能自动恢复）
      widget.controller.autoMode = true;
      _loadSavedAndAutoConnect();
    } else if (widget.pendingShareToken != null) {
      // 扫描共享二维码：立即连接（携带共享码加入共享目录）
      widget.controller.autoMode = false;
      _connect(shareToken: widget.pendingShareToken);
    }
  }

  /// 读取上次配对信息并自动连接（无需再次扫码/输入）
  Future<void> _loadSavedAndAutoConnect() async {
    AppLog.i('connect', '冷启动自动直连模式，读取历史配对信息…');
    final info = await widget.controller.loadPairInfo();
    if (!mounted || info == null) return;
    AppLog.i('connect', '自动直连: server=${info.server} (autoMode=${widget.controller.autoMode})');
    _server = info.server;
    _codeCtrl.text = info.code.toUpperCase();
    setState(() => _submitted = true);
    // 直接调用 connect（不走 _connect：它会关闭自动重试模式，
    // 导致电脑端未上线时既不重试也不进入主页面）
    await widget.controller.connect(info.server, info.code.toUpperCase());
    if (!mounted) return;
    await _waitForPair();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect({String? shareToken}) async {
    // 手动/扫码连接：失败立即提示，不自动重试
    widget.controller.autoMode = false;
    final server = _server.trim().replaceAll(RegExp(r'/$'), '');
    final code = _codeCtrl.text.trim().toUpperCase();
    if (!kPairCodeRegExp.hasMatch(code)) {
      _showError('配对码为 10 位数字/字母');
      return;
    }
    AppLog.i('connect',
        '手动连接: server=$server${shareToken != null ? ' (带共享码)' : ''} (autoMode=${widget.controller.autoMode})');
    setState(() => _submitted = true);
    await widget.controller.connect(server, code, shareToken: shareToken);
    if (!mounted) return;

    // 等待配对结果
    await _waitForPair();
  }

  /// 扫码配对：扫描电脑端二维码，自动填入服务器地址与配对码并连接
  Future<void> _scanPair() async {
    final result = await Navigator.of(context).push<ScanPairResult>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) {
      AppLog.i('connect', '扫码取消或未识别');
      return;
    }
    AppLog.i('connect',
        '扫码成功: server=${result.server}${result.shareToken != null ? ' (共享码)' : ''}');
    _server = result.server;
    _codeCtrl.text = result.code.toUpperCase();
    await _connect(shareToken: result.shareToken);
  }

  Future<void> _waitForPair() async {
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 300));
      final s = widget.controller.state;
      if (s == ConnectState.paired || s == ConnectState.peerConnected) {
        // 配对成功：保存信息，下次启动自动直连
        // （共享访客扫码连接不保存：避免下次启动自动直连而成为配对客户端）
        AppLog.i('connect', '配对成功，进入主页'
            '${widget.pendingShareToken != null ? '（共享访客）' : ''}');
        if (widget.pendingShareToken == null) {
          await widget.controller.savePairInfo(
            _server.trim(),
            _codeCtrl.text.trim().toUpperCase(),
          );
        }
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
        final err = widget.controller.errorMessage ?? '';
        AppLog.w('connect', '配对失败: $err');
        setState(() {
          _submitted = false;
          // 配对码无效：旧码已失效，清空输入框，引导重新扫码配对
          if (err.contains('配对码无效')) _codeCtrl.clear();
        });
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
                      Text('P2P 文件助手 v$appVersion',
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
                          child: Column(
                            children: [
                              Text(
                                controller.errorMessage ?? '连接失败',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: theme.colorScheme.error,
                                    fontWeight: FontWeight.w500),
                              ),
                              if ((controller.errorMessage ?? '')
                                  .contains('配对码无效'))
                                const Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text(
                                    '请点击上方「扫码配对」扫描电脑端二维码，\n或输入电脑端显示的最新配对码',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey),
                                  ),
                                ),
                            ],
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
                              '1. 电脑打开 P2P 软件，界面显示 10 位配对码\n'
                              '2. 手机扫码自动填入，或手动输入配对码\n'
                              '3. 连接成功即可浏览/传输电脑文件',
                              style: TextStyle(fontSize: 13, height: 1.6),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 版本号：调试时确认是否最新版本
                      Center(
                        child: Text(
                          'v$appVersion',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
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
