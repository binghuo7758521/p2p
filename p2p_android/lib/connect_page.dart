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

  /// 配对历史（最近连接过的电脑/共享文件夹）
  List<PairInfo> _history = [];
  bool _historyLoaded = false;

  /// 当前连接携带的共享码（历史共享条目/扫码共享二维码时非空）
  String? _connectShareToken;

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
      _connectShareToken = widget.pendingShareToken;
      _connect(shareToken: widget.pendingShareToken);
    }
  }

  /// 读取配对历史并决定是否自动直连：
  /// 仅一台电脑记录 → 自动直连（与旧版行为一致）；
  /// 多台电脑/有共享记录 → 停留连接页展示列表供用户选择
  Future<void> _loadSavedAndAutoConnect() async {
    AppLog.i('connect', '冷启动自动直连模式，读取配对历史…');
    final list = await widget.controller.loadPairInfos();
    if (!mounted) return;
    setState(() {
      _history = list;
      _historyLoaded = true;
    });
    final pcList = list.where((p) => !p.isShare).toList();
    if (pcList.length != 1) return; // 0 台停留连接页；多台让用户选择
    final info = pcList.first;
    AppLog.i('connect',
        '自动直连: server=${info.server} (autoMode=${widget.controller.autoMode})');
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

  /// 从历史列表选择连接（电脑或共享文件夹）
  Future<void> _connectFromHistory(PairInfo info) async {
    // 手动选择：失败立即提示，不自动重试
    widget.controller.autoMode = false;
    _server = info.server;
    _codeCtrl.text = info.code.toUpperCase();
    _connectShareToken = info.shareToken;
    setState(() => _submitted = true);
    AppLog.i('connect',
        '从历史选择连接: ${info.isShare ? '共享' : '电脑'} code=${info.code}');
    await widget.controller.connect(info.server, info.code.toUpperCase(),
        shareToken: info.shareToken);
    if (!mounted) return;
    await _waitForPair();
  }

  /// 删除一条配对历史（确认后移除）
  Future<void> _removeHistory(PairInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('删除后将不再显示「${info.name ?? '电脑 ${_codeSuffix(info.code)}'}」\n确认删除？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.controller
        .removePairInfo(info.server, info.code, shareToken: info.shareToken);
    if (!mounted) return;
    setState(() => _history.removeWhere(
        (h) => h.server == info.server && h.code == info.code));
  }

  Future<void> _connect({String? shareToken}) async {
    // 手动/扫码连接：失败立即提示，不自动重试
    widget.controller.autoMode = false;
    if (shareToken != null) _connectShareToken = shareToken;
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
        final share = _connectShareToken;
        // 配对成功：保存历史（共享访客带共享码标记，仅列表可选，
        // 不会成为下次启动自动直连的目标）
        // 名称优先用电脑端备注名（hostName），其次码尾/共享文件夹名
        final hostName = widget.controller.hostName;
        AppLog.i('connect',
            '配对成功，进入主页${share != null ? '（共享访客）' : ''}');
        await widget.controller.savePairInfo(
          _server.trim(),
          _codeCtrl.text.trim().toUpperCase(),
          name: (hostName != null && hostName != '电脑')
              ? hostName
              : _displayName(_codeCtrl.text.trim().toUpperCase(), share),
          shareToken: share,
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

  /// 历史条目标题：电脑用码尾 4 位区分；共享用共享文件夹名
  String _displayName(String code, String? shareToken) {
    if (shareToken != null && shareToken.isNotEmpty) {
      for (final s in widget.controller.shares) {
        if (s.token == shareToken) return s.name;
      }
      return '共享文件夹';
    }
    return '电脑 ${_codeSuffix(code)}';
  }

  /// 配对码尾 4 位（多台电脑区分标识）
  static String _codeSuffix(String code) =>
      code.length >= 4 ? code.substring(code.length - 4) : code;

  /// 最近连接时间的相对描述
  static String _fmtTime(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
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

                      // 最近连接过的电脑/共享文件夹（点击连接，垃圾桶删除）
                      if (_historyLoaded && _history.isNotEmpty) ...[
                        Text('最近连接',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        for (final h in _history)
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            elevation: 0,
                            color: theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                  h.isShare
                                      ? Icons.folder_shared
                                      : Icons.desktop_windows,
                                  color: h.isShare
                                      ? const Color(0xFF38BDF8)
                                      : theme.colorScheme.primary),
                              title: Text(h.name ??
                                  (h.isShare
                                      ? '共享文件夹'
                                      : '电脑 ${_codeSuffix(h.code)}')),
                              subtitle: Text(
                                '${h.isShare ? '' : '配对码 ${h.code}'}'
                                '${_fmtTime(h.lastAt).isEmpty ? '' : ' · ${_fmtTime(h.lastAt)}'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20),
                                tooltip: '删除记录',
                                onPressed: busy
                                    ? null
                                    : () => _removeHistory(h),
                              ),
                              onTap: busy
                                  ? null
                                  : () => _connectFromHistory(h),
                            ),
                          ),
                        const SizedBox(height: 16),
                      ],

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
