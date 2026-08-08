import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'home_page.dart';
import 'host_controller.dart';

/// 电脑端连接页：服务器地址 + 共享目录 + 配对码展示
class ConnectPage extends StatefulWidget {
  final HostController controller;

  const ConnectPage({super.key, required this.controller});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _serverCtrl =
      TextEditingController(text: 'http://182.92.157.93:3000');
  bool _connecting = false;

  @override
  void dispose() {
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final server = _serverCtrl.text.trim().replaceAll(RegExp(r'/$'), '');
    if (server.isEmpty) {
      _showError('请输入服务器地址');
      return;
    }
    final c = widget.controller;
    // 默认共享「我的电脑」，无需设置；手动选择后按所选目录共享
    setState(() => _connecting = true);
    await c.connect(server: server);
    if (!mounted) return;
    await _waitForPeer();
  }

  Future<void> _waitForPeer() async {
    final c = widget.controller;
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 300));
      final s = c.state;
      if (s == HostState.peerConnected) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => HomePage(controller: c)),
        );
        return;
      }
      if (s == HostState.idle && c.errorMessage != null) {
        if (!mounted) return;
        setState(() => _connecting = false);
        return;
      }
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) {
                  final registered = c.state == HostState.registered;
                  final connected = c.state == HostState.peerConnected;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.swap_horiz_rounded,
                          size: 64, color: Color(0xFF38BDF8)),
                      const SizedBox(height: 12),
                      Text('P2P 文件助手 - 电脑端',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('与手机 App 互通 · WebRTC 直连',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: Colors.grey)),
                      const SizedBox(height: 24),

                      // 服务器地址
                      TextField(
                        controller: _serverCtrl,
                        enabled: !_connecting,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: '信令服务器地址',
                          hintText: 'http://182.92.157.93:3000',
                          prefixIcon: Icon(Icons.dns_outlined),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 共享范围
                      OutlinedButton.icon(
                        onPressed:
                            _connecting ? null : () => c.pickSharedDir(),
                        icon: const Icon(Icons.folder_open),
                        label: Text(
                            c.myComputerMode
                                ? '共享范围: 我的电脑（全部磁盘/桌面等）'
                                : '共享目录: ${c.sharedDir!.path}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 14)),
                      ),
                      if (!c.myComputerMode)
                        TextButton(
                          onPressed: _connecting
                              ? null
                              : () => c.restoreMyComputer(),
                          child: const Text('恢复默认: 共享我的电脑'),
                        ),
                      const SizedBox(height: 16),

                      // 开始按钮 / 配对码展示
                      if (!registered && !connected)
                        FilledButton.icon(
                          onPressed: _connecting ? null : _start,
                          icon: _connecting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.link),
                          label: Text(_connecting
                              ? '连接中...'
                              : '连接并生成配对码'),
                          style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                        ),

                      if (registered && !connected) ...[
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Text('请在手机上输入配对码',
                                  style: theme.textTheme.bodyMedium),
                              const SizedBox(height: 8),
                              Text(
                                c.pairCode,
                                style: theme.textTheme.headlineSmall
                                    ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 4,
                                  color: const Color(0xFFF59E0B),
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              // 扫码配对二维码：p2p:<服务器地址>|<配对码>
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: QrImageView(
                                  data:
                                      'p2p:${c.serverUrl}|${c.pairCode}',
                                  version: QrVersions.auto,
                                  size: 160,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text('手机端扫码自动填入服务器地址与配对码',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey)),
                              const SizedBox(height: 8),
                              const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                  SizedBox(width: 8),
                                  Text('等待手机连接...',
                                      style: TextStyle(fontSize: 13)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              TextButton.icon(
                                onPressed: () {
                                  c.resetPairCode();
                                  _showError('已重新生成配对码，手机端需用新码/新二维码重新配对');
                                },
                                icon: const Icon(Icons.refresh, size: 18),
                                label: const Text('重新生成配对码'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () async {
                            await c.disconnect();
                            if (mounted) setState(() => _connecting = false);
                          },
                          child: const Text('断开'),
                        ),
                      ],

                      if (connected) ...[
                        const SizedBox(height: 16),
                        const Center(
                            child: Text('手机已连接，正在进入主界面...')),
                      ],

                      if (c.errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            c.errorMessage!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: theme.colorScheme.error,
                                fontSize: 13),
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
