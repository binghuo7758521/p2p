import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'dart:io';

import 'app_log.dart';
import 'auto_login.dart';
import 'auto_start.dart';
import 'home_page.dart';
import 'host_controller.dart';
import 'license_check.dart';
import 'update_check.dart';
import 'usb_drives.dart';
import 'version.dart';

/// 电脑端连接页：共享目录 + 等待手机激活连接（v6.13+ 配对码内部化，不再展示）
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

  // 重启后自动登录开关状态
  bool _autoLogin = false;
  bool _autoLoginLoading = true;
  bool _elevated = false; // 当前进程是否以管理员身份运行（远程设置前置条件）

  // 已检测到的 U 盘（启动时枚举一次，卷序列号可作本机标识）
  List<UsbDriveInfo> _usbDrives = [];
  bool _usbLoading = true;

  // ── U盘授权验证状态 ──
  bool _licensing = false; // 验证中
  bool _licenseDenied = false; // 未授权/验证失败，锁定程序
  LicenseResult? _licenseResult;

  @override
  void initState() {
    super.initState();
    _loadAutoStart();
    _loadAutoLogin();
    _loadUsbDrives();
    // 启动流程：先 U盘授权验证，通过后再自动注册上线
    // （等首帧渲染完成再发起，避免 setState 时机问题）
    WidgetsBinding.instance.addPostFrameCallback((_) => _startLicenseCheck());
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

  Future<void> _loadAutoStart() async {
    final enabled = await AutoStartService.isEnabled();
    if (!mounted) return;
    setState(() {
      _autoStart = enabled;
      _autoStartLoading = false;
    });
  }

  Future<void> _loadAutoLogin() async {
    final enabled = await AutoLoginService.isEnabled();
    final elevated = await AutoLoginService.isElevated();
    if (!mounted) return;
    setState(() {
      _autoLogin = enabled;
      _autoLoginLoading = false;
      _elevated = elevated;
    });
  }

  /// 重启后自动登录开关：开启需输入 Windows 登录密码（UAC 提权写注册表），
  /// 关闭即删除密码项恢复普通登录
  Future<void> _toggleAutoLogin(bool v) async {
    if (v) {
      final pwd = await _askAutoLoginPassword();
      if (pwd == null) return; // 用户取消
      setState(() => _autoLoginLoading = true);
      final ok = await AutoLoginService.enable(pwd);
      if (!mounted) return;
      setState(() {
        _autoLogin = ok;
        _autoLoginLoading = false;
      });
      if (ok) {
        _showTip('已开启重启后自动登录，下次重启生效');
      } else {
        _showError('开启自动登录失败（UAC 未确认或注册表写入失败）');
      }
    } else {
      setState(() => _autoLoginLoading = true);
      final ok = await AutoLoginService.disable();
      if (!mounted) return;
      setState(() {
        _autoLogin = ok ? false : true; // 失败时保持开启
        _autoLoginLoading = false;
      });
      if (!ok) _showError('关闭自动登录失败（UAC 未确认）');
    }
  }

  /// 输入 Windows 登录密码弹窗（仅写入本机注册表，明文存储风险提示）
  Future<String?> _askAutoLoginPassword() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.lock_open, color: Color(0xFF38BDF8)),
        title: const Text('开启重启后自动登录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Windows 登录密码',
                hintText: '请输入开机登录时用的密码',
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '密码将以明文存储于本机注册表（HKLM\\...\\Winlogon），'
              '本机其他管理员可读取，建议仅在可信环境开启。\n'
              '若系统盘启用了 BitLocker 加密，重启时仍需先解锁磁盘，本功能无效。',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.isEmpty) return;
              Navigator.of(ctx).pop(ctrl.text);
            },
            child: const Text('开启'),
          ),
        ],
      ),
    );
  }

  /// 轻提示（开关操作成功反馈）
  void _showTip(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 3),
    ));
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

  /// U盘授权验证：本机U盘ID在服务器白名单中才允许使用；
  /// 未授权给出购买方式并锁定；服务器不可达也锁定并提示重试
  Future<void> _startLicenseCheck() async {
    setState(() {
      _licensing = true;
      _licenseDenied = false;
    });
    final result = await verifyLicense(defaultServerUrl);
    if (!mounted) return;
    if (!result.licensed) {
      setState(() {
        _licensing = false;
        _licenseDenied = true;
        _licenseResult = result;
      });
      AppLog.w('license', result.error ??
          '未授权U盘，程序锁定（购买方式: ${result.buyWechat} / ${result.buyPhone}）');
      return;
    }
    setState(() => _licensing = false);
    await _connect();
  }

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
      // 已有管理员（本地持久化过 adminDeviceId）：不再停留扫码页，
      // 直接进入主页面等待手机连接（状态变化由 ListenableBuilder 自动刷新）
      if (s == HostState.registered && c.hasAdmin) {
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

  /// 未授权锁定页：说明原因 + 购买方式 + 重新验证/退出
  Widget _buildLicenseDenied(ThemeData theme) {
    final r = _licenseResult;
    final reachable = r?.reachable ?? false;
    final buyLines = [
      if (r != null && r.buyTitle.isNotEmpty) r.buyTitle,
      if (r != null && r.buyWechat.isNotEmpty) r.buyWechat,
      if (r != null && r.buyPhone.isNotEmpty) r.buyPhone,
    ];
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(reachable ? Icons.usb_off : Icons.cloud_off,
                      size: 72, color: Colors.redAccent),
                  const SizedBox(height: 16),
                  Text(
                    reachable ? '未授权使用' : '无法验证授权',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    reachable
                        ? '当前电脑未检测到已授权的U盘，程序无法使用。\n'
                            '请插入已授权的U盘后重新验证。'
                        : (r?.error ?? '网络异常'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.grey),
                  ),
                  if (reachable && buyLines.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            for (final line in buyLines)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Text(
                                  line,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                      color: const Color(0xFFF59E0B)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed:
                        _licensing ? null : () => _startLicenseCheck(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新验证'),
                    style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14)),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => exit(0),
                    child: const Text('退出程序'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);

    // 授权验证中
    if (_licensing) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text('正在验证U盘授权…',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    // 未授权 / 验证失败：锁定并展示购买方式
    if (_licenseDenied) {
      return _buildLicenseDenied(theme);
    }

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
                      Text('无限大盘 - 电脑端',
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

                      // 重启后自动登录开关（v6.5+：配合开机自启实现无人值守）
                      Card(
                        margin: EdgeInsets.zero,
                        child: SwitchListTile(
                          value: _autoLogin,
                          onChanged: _autoLoginLoading
                              ? null
                              : _toggleAutoLogin,
                          secondary: const Icon(Icons.lock_open),
                          title: const Text('重启后自动登录'),
                          subtitle: Text(
                            _autoLoginLoading
                                ? '读取中...'
                                : (_autoLogin
                                    ? '已开启：重启后免输密码直接进入桌面'
                                    : '已关闭：重启后需输入 Windows 密码'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      // v6.6+：远程设置前置条件提示（未提权时）
                      if (!_elevated)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '提示：手机端远程设置自动登录需本程序以管理员身份运行，'
                            '请右键程序图标选择“以管理员身份运行”后重试',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.orange),
                          ),
                        ),
                      const SizedBox(height: 16),

                      // 开始按钮 / 等待手机激活连接
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
                          label: Text(_connecting ? '连接中...' : '开始使用'),
                          style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                        ),

                      if (registered && !connected) ...[
                        // v6.14+：首次无管理员直接展示管理员激活码；有管理员时等待手机连接
                        if (!c.hasAdmin)
                          _BootCodeCard(
                            controller: c,
                            theme: theme,
                            code: c.ensureBootAdminCode() ?? '',
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Column(
                              children: [
                                Row(
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
                                SizedBox(height: 8),
                                Text(
                                  '新设备需管理员在「手机端管理」页生成激活码后\n扫码激活，激活后自动连接本电脑',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.grey),
                                  textAlign: TextAlign.center,
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

/// 首启管理员激活码卡片：大字码 + 二维码（p2p-act:server|code）+ 复制
class _BootCodeCard extends StatelessWidget {
  final HostController controller;
  final ThemeData theme;
  final String code;

  const _BootCodeCard({
    required this.controller,
    required this.theme,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    final qrData = 'p2p-act:${controller.serverUrl}|$code';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Text('首次使用：手机扫码激活成为管理员',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          QrImageView(data: qrData, size: 160),
          const SizedBox(height: 12),
          SelectableText(
            code,
            style: const TextStyle(
                fontSize: 24,
                letterSpacing: 4,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text('24 小时内有效，使用一次后作废',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制激活码'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('已复制'), duration: Duration(seconds: 1)));
            },
          ),
        ],
      ),
    );
  }
}
