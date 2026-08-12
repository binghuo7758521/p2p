import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'auto_start.dart';
import 'home_page.dart';
import 'host_controller.dart';
import 'update_check.dart';
import 'usb_drives.dart';
import 'version.dart';

/// 电脑端连接页：共享目录 + 配对码展示
class ConnectPage extends StatefulWidget {
  final HostController controller;

  const ConnectPage({super.key, required this.controller});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  bool _connecting = false;

  // 开机自启开关状态
  bool _autoStart = false;
  bool _autoStartLoading = true;

  // 已检测到的 U 盘（启动时枚举一次，卷序列号可作本机标识）
  List<UsbDriveInfo> _usbDrives = [];
  bool _usbLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAutoStart();
    _checkUpdate();
    _loadUsbDrives();
    // 启动后自动注册上线：无需手动点击「连接并生成配对码」
    // （等首帧渲染完成再发起，避免 setState 时机问题）
    WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  /// 枚举所有 U 盘（GetVolumeInformation 对每个盘符一次查询，耗时可控）
  Future<void> _loadUsbDrives() async {
    final drives = await Future(() => listUsbDrives());
    if (!mounted) return;
    setState(() {
      _usbDrives = drives;
      _usbLoading = false;
    });
  }

  /// 启动时检查升级：服务器有新版本时弹窗提示（每次启动检查一次）
  Future<void> _checkUpdate() async {
    final info = await checkDesktopUpdate();
    if (!mounted || info == null || !info.needUpdate) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: Text('发现新版本 v${info.latest}'),
        content: Text(
          '当前版本 v$appVersion\n\n${info.notes}\n\n'
          '升级包下载后：解压覆盖原程序目录（先关闭正在运行的程序）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (info.url != null) openDownloadUrl(info.url!);
            },
            icon: const Icon(Icons.download, size: 18),
            label: const Text('立即下载'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadAutoStart() async {
    final enabled = await AutoStartService.isEnabled();
    if (!mounted) return;
    setState(() {
      _autoStart = enabled;
      _autoStartLoading = false;
    });
  }

  Future<void> _toggleAutoStart(bool v) async {
    setState(() => _autoStartLoading = true);
    final ok =
        v ? await AutoStartService.enable() : await AutoStartService.disable();
    if (!mounted) return;
    setState(() {
      _autoStart = ok ? v : !v; // 失败时回滚开关状态
      _autoStartLoading = false;
    });
    if (!ok) _showError(v ? '开启开机自启失败' : '关闭开机自启失败');
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _start() => _connect();

  /// 连接信令服务器并注册为在线主机
  /// 默认连接公网信令服务器；默认共享「我的电脑」，手动选择后按所选目录共享
  Future<void> _connect() async {
    final c = widget.controller;
    if (c.state != HostState.idle || _connecting) return;
    setState(() => _connecting = true);
    await c.connect(server: defaultServerUrl);
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

                      // 已检测到的 U 盘列表（卷序列号每块 U 盘唯一，可作本机标识）
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.usb,
                                      size: 18, color: Color(0xFF38BDF8)),
                                  const SizedBox(width: 8),
                                  Text(
                                    'U 盘设备 (${_usbDrives.length})',
                                    style: theme.textTheme.titleSmall
                                        ?.copyWith(
                                            fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              if (_usbLoading)
                                const Text('检测中...',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey))
                              else if (_usbDrives.isEmpty)
                                const Text('未检测到 U 盘',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.grey))
                              else
                                for (final d in _usbDrives)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(bottom: 4),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.rectangle_outlined,
                                            size: 14,
                                            color: Color(0xFFF59E0B)),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            '${d.letter}: ${d.volumeLabel.isEmpty ? '(无卷标)' : d.volumeLabel}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 12),
                                          ),
                                        ),
                                        Text('ID: ${d.serial}',
                                            style: const TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 开机自动运行开关
                      Card(
                        margin: EdgeInsets.zero,
                        child: SwitchListTile(
                          value: _autoStart,
                          onChanged: _autoStartLoading
                              ? null
                              : _toggleAutoStart,
                          secondary:
                              const Icon(Icons.power_settings_new),
                          title: const Text('开机自动运行'),
                          subtitle: Text(
                            _autoStartLoading
                                ? '读取中...'
                                : (_autoStart
                                    ? '已开启：开机后自动启动本程序'
                                    : '已关闭：开机不自动启动'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
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
                              const Text('手机端扫码自动填入配对码',
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
                      const SizedBox(height: 20),
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
