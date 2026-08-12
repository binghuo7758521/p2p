import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'app_controller.dart';
import 'app_log.dart';
import 'auth_service.dart';
import 'connect_page.dart';
import 'models.dart';
import 'protocol.dart';
import 'scan_page.dart';
import 'share_browse_page.dart';
import 'users_page.dart';
import 'version.dart';
import 'video_play_service.dart';
import 'video_player_page.dart';

/// 主界面：浏览 / 上传 / 传输
class HomePage extends StatefulWidget {
  final AppController controller;

  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  bool _claimDialogShowing = false; // 管理员更换确认弹窗防重复

  @override
  void initState() {
    super.initState();
    _maybeAutoConnect();
  }

  /// 冷启动（主页为登录后第一页）：有历史配对信息则自动直连；
  /// 无配对信息（没有自己的电脑）停留未连接视图，可手动连接或浏览共享
  Future<void> _maybeAutoConnect() async {
    final c = widget.controller;
    if (c.state != ConnectState.idle) return; // 已在连接/已连接/重连中
    final info = await c.loadPairInfo();
    if (!mounted || info == null) return;
    c.autoMode = true;
    AppLog.i('connect', '主页自动直连: server=${info.server}');
    await c.connect(info.server, info.code.toUpperCase());
  }

  /// 扫描共享二维码：已连同一电脑端直接附加共享，否则跳连接页自动连接
  Future<void> _scanShareCode() async {
    final result = await Navigator.of(context).push<ScanPairResult>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) return;
    final ctrl = widget.controller;
    AppLog.i('share',
        '扫码: server=${result.server} code=${result.code} token=${result.shareToken}');
    if (result.shareToken != null &&
        ctrl.state == ConnectState.peerConnected &&
        result.server == ctrl.lastServerUrl &&
        result.code.toUpperCase() == ctrl.lastPairCode?.toUpperCase()) {
      // 已连接同一电脑端：直接附加共享目录
      ctrl.attachShare(result.shareToken!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('正在附加共享目录…'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    // 未连接/其他电脑端：进入连接页自动连接（携带共享码）
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConnectPage(
        controller: ctrl,
        autoConnect: false,
        initialServer: result.server,
        initialCode: result.code,
        pendingShareToken: result.shareToken,
      ),
    ));
  }

  /// 显示操作结果提示（共享附加/删除等，显示后自动清除）
  void _showActionMessage(AppController controller) {
    final msg = controller.actionMessage;
    if (msg == null) return;
    controller.clearActionMessage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
    });
  }

  /// 电脑端已有其他管理员：弹出更换确认（确认后申请成为管理员）
  void _maybeShowAdminClaimDialog(AppController c) {
    final req = c.adminClaimRequest;
    if (req == null || _claimDialogShowing || !mounted) return;
    _claimDialogShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('更换管理员'),
          content: Text('该电脑端已有管理员（${req.maskedPhone}）\n\n'
              '是否将管理员更换为您？原管理员将自动降级为普通用户。'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                c.rejectAdminClaim();
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                c.confirmAdminClaim();
              },
              child: const Text('更换为管理员'),
            ),
          ],
        ),
      ).then((_) => _claimDialogShowing = false);
    });
  }

  /// 一键上传运行日志到服务器（开发者远程排查用）
  Future<void> _uploadLog() async {
    final server = widget.controller.lastServerUrl;
    final messenger = ScaffoldMessenger.of(context);
    if (server == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('未连接服务器，无法上传日志')));
      return;
    }
    messenger.showSnackBar(const SnackBar(
        content: Text('正在上传日志…'), duration: Duration(seconds: 2)));
    try {
      final logText = await AppLog.readLog();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final uri = Uri.parse('$server/log-upload').replace(queryParameters: {
          'deviceId': widget.controller.deviceId,
          'version': appVersion,
          'phone': AuthService.instance.phone ?? '',
        });
        final req = await client.postUrl(uri);
        req.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        req.write(logText);
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode == 200) {
          final logId = (jsonDecode(body) as Map)['logId'] ?? '';
          AppLog.i('upload', '日志上传成功: $logId');
          messenger.showSnackBar(SnackBar(
              content: Text('日志已上传（$logId），请告知开发者')));
        } else {
          AppLog.e('upload', '日志上传失败: HTTP ${resp.statusCode}');
          messenger.showSnackBar(
              const SnackBar(content: Text('日志上传失败，请稍后重试')));
        }
      } finally {
        client.close();
      }
    } catch (e) {
      AppLog.e('upload', '日志上传异常', e);
      messenger.showSnackBar(
          SnackBar(content: Text('日志上传失败: $e')));
    }
  }

  /// 下载完成：弹操作面板（打开 / 保存到手机 / 分享）
  void _showDownloadDone(AppController controller) {
    final done = controller.takeLastDownloadDone();
    if (done == null) return;
    AppLog.i('download', '弹出下载完成操作面板: ${done.name}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('下载完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(done.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '文件已保存在应用目录。点"保存到手机"可存到下载、相册等任意位置。',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final r = await OpenFilex.open(done.path);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(r.type == ResultType.done
                      ? '已打开: ${done.name}'
                      : '无法打开该文件: ${r.message}'),
                  duration: const Duration(seconds: 2),
                ));
              },
              child: const Text('打开'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  final saved = await FlutterFileDialog.saveFile(
                      params: SaveFileDialogParams(
                    sourceFilePath: done.path,
                    fileName: done.name,
                  ));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(saved != null
                        ? '已保存到: $saved'
                        : '已取消保存'),
                    duration: const Duration(seconds: 3),
                  ));
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('保存失败: $e'),
                    duration: const Duration(seconds: 3),
                  ));
                }
              },
              child: const Text('保存到手机'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await SharePlus.instance.share(ShareParams(
                  files: [XFile(done.path)],
                  text: '已从电脑下载: ${done.name}',
                ));
              },
              child: const Text('分享'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final connected =
                controller.state == ConnectState.peerConnected;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('P2P 文件助手 v$appVersion',
                    style: const TextStyle(fontSize: 18)),
                Text(
                  connected
                      ? '已连接: ${controller.hostName ?? '电脑'}'
                      : '未连接',
                  style: TextStyle(
                      fontSize: 12,
                      color: connected ? Colors.green : Colors.redAccent),
                ),
                if (connected) ...[const SizedBox(width: 6), _ConnBadge(controller: controller)],
              ],
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: '扫共享二维码',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanShareCode,
          ),
          ListenableBuilder(
            listenable: controller,
            // 共享文件夹管理入口（仅管理员显示）：
            // 非管理员/共享访客无权限，不再展示
            builder: (context, _) =>
                controller.state == ConnectState.peerConnected &&
                        controller.isAdmin
                    ? IconButton(
                        tooltip: '共享文件夹管理',
                        icon: const Icon(Icons.folder_shared_outlined),
                        onPressed: () {
                          controller.refreshUserList();
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  UsersPage(controller: controller)));
                        },
                      )
                    : const SizedBox.shrink(),
          ),
          IconButton(
            tooltip: '复制运行日志',
            icon: const Icon(Icons.article_outlined),
            onPressed: () async {
              final logText = await AppLog.readLog();
              if (!context.mounted) return;
              await Clipboard.setData(ClipboardData(text: logText));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('运行日志已复制，请直接粘贴给开发者排查'),
              ));
            },
          ),
          IconButton(
            tooltip: '上传日志给开发者',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: _uploadLog,
          ),
          IconButton(
            tooltip: '断开连接',
            icon: const Icon(Icons.link_off),
            onPressed: () async {
              // 断开后停留在主页（未连接引导视图），不再强制跳连接页
              await controller.disconnect();
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          _showActionMessage(controller);
          _showDownloadDone(controller);
          _maybeShowAdminClaimDialog(controller);
          if (controller.state == ConnectState.lost) {
            return _LostView(controller: controller);
          }
          if (controller.state != ConnectState.peerConnected) {
            // 未连接（idle/connecting/paired/error）：显示连接引导视图，
            // 不阻塞主页面使用（无电脑端权限的客户端也可浏览分享的共享文件夹）
            return _NotConnectedView(controller: controller);
          }
          return IndexedStack(
            // 共享访客模式隐藏「上传」页签（_tab==1）：显示浏览页
            index: controller.isShareGuest && _tab == 1 ? 0 : _tab,
            children: [
              _BrowseTab(controller: controller),
              _UploadTab(controller: controller),
              _TransfersTab(controller: controller),
            ],
          );
        },
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final guest = controller.isShareGuest;
          return NavigationBar(
            selectedIndex: guest ? (_tab >= 2 ? 1 : 0) : _tab,
            onDestinationSelected: (i) {
              // 共享访客模式无「上传」页签：导航索引映射回真实页签
              setState(() => _tab = guest ? (i == 1 ? 2 : 0) : i);
              if (_tab == 0) controller.requestFileList();
            },
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '浏览'),
              if (!guest)
                const NavigationDestination(
                    icon: Icon(Icons.upload_outlined),
                    selectedIcon: Icon(Icons.upload),
                    label: '上传'),
              const NavigationDestination(
                  icon: Icon(Icons.swap_vert_outlined),
                  selectedIcon: Icon(Icons.swap_vert),
                  label: '传输'),
            ],
          );
        },
      ),
    );
  }
}

class _ConnBadge extends StatelessWidget {
  final AppController controller;

  const _ConnBadge({required this.controller});

  @override
  Widget build(BuildContext context) {
    final relay = controller.connectionType == 'relay';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (relay ? Colors.orange : Colors.green).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        controller.connTypeLabel,
        style: TextStyle(
          fontSize: 10,
          color: relay ? Colors.orange : Colors.green,
        ),
      ),
    );
  }
}

/// 未连接引导视图：不连接电脑也可进入主页面，
/// 需要电脑端功能时点击「连接电脑」进入连接页手动连接
class _NotConnectedView extends StatelessWidget {
  final AppController controller;

  const _NotConnectedView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    final connecting = s == ConnectState.connecting || s == ConnectState.paired;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connecting)
              const CircularProgressIndicator()
            else
              Icon(Icons.link_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              connecting ? '正在连接电脑…' : '未连接电脑',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              connecting
                  ? '请稍候'
                  : (controller.errorMessage ??
                      '连接电脑后可浏览/传输文件，\n也可查看分享给你的共享文件夹'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 20),
            if (!connecting)
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ConnectPage(
                        controller: controller, autoConnect: false),
                  ));
                },
                icon: const Icon(Icons.link),
                label: const Text('连接电脑'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 连接丢失视图
class _LostView extends StatelessWidget {
  final AppController controller;

  const _LostView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text(controller.errorMessage ?? '连接已断开',
              style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 4),
          const Text('正在自动重连，请保持电脑端开启…',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              // 断开自动重连，回到主页未连接视图；
              // 如需手动连接从主页「连接电脑」入口进入
              await controller.disconnect();
            },
            child: const Text('停止重连'),
          ),
        ],
      ),
    );
  }
}

/// 浏览页签
class _BrowseTab extends StatelessWidget {
  final AppController controller;

  const _BrowseTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final path = controller.dirPath;
    final segments = path.isEmpty ? <String>[] : path.split('/');

    // 共享访客模式（扫码共享连接）：只显示共享入口与引导，
    // 不展示「我的电脑」文件区（浏览/上传/删除主目录均无权限）
    if (controller.isShareGuest) {
      return Column(
        children: [
          if (controller.shares.isNotEmpty) _shareEntries(context, controller),
          Expanded(
            child: _MessageView(
              icon: Icons.folder_shared_outlined,
              text: controller.shares.isNotEmpty
                  ? '共享访问模式：点击上方共享文件夹浏览，\n只能操作分享给你的内容'
                  : '共享访问模式：暂无分享给你的共享文件夹',
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        // 共享目录入口（扫码加入的共享，点击进入共享浏览页）
        if (controller.shares.isNotEmpty) _shareEntries(context, controller),
        // 路径面包屑
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            children: [
              ActionChip(
                label: const Text('远程电脑'),
                onPressed: () => controller.navigateTo(-1),
              ),
              for (var i = 0; i < segments.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ActionChip(
                    label: Text(segments[i]),
                    onPressed: () => controller.navigateTo(i),
                  ),
                ),
            ],
          ),
        ),
        // 下载进度提示
        if (controller.activeDownloadName != null)
          _DownloadBanner(controller: controller),
        // 文件列表
        Expanded(child: _buildList(context, controller)),
      ],
    );
  }

  /// 共享目录入口列表（横向 chips）
  Widget _shareEntries(BuildContext context, AppController controller) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          for (final s in controller.shares)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: const Icon(Icons.folder_shared,
                    size: 16, color: Color(0xFF0D9488)),
                label: Text(s.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () {
                  controller.openShare(s);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          ShareBrowsePage(controller: controller)));
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, AppController controller) {
    if (controller.listLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.listError != null) {
      return _MessageView(
        icon: Icons.error_outline,
        text: controller.listError!,
      );
    }
    if (controller.files.isEmpty) {
      return const _MessageView(
        icon: Icons.folder_off_outlined,
        text: '此目录为空',
      );
    }
    return RefreshIndicator(
      onRefresh: () => controller.requestFileList(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: controller.files.length,
        itemBuilder: (context, i) {
          final f = controller.files[i];
          return _FileTile(
            entry: f,
            onTap: () {
              if (f.isDirectory) {
                controller.openDir(f);
              } else {
                controller.downloadFile(f);
              }
            },
            // 删除等危险操作不常显在列表中（防误触），改为长按弹出操作菜单
            onLongPress: () => _showFileActions(context, controller, f),
            onPlay: !f.isDirectory && isVideoFile(f.name)
                ? () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => VideoPlayerPage(
                          controller: controller, entry: f),
                    ));
                  }
                : null,
          );
        },
      ),
    );
  }
  /// 长按文件操作菜单（防误触：删除等危险操作不再常显在列表中）
  Future<void> _showFileActions(
      BuildContext context, AppController controller, FileEntry f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                f.isDirectory ? Icons.folder : Icons.insert_drive_file,
                color: f.isDirectory
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFF38BDF8),
              ),
              title: Text(f.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: f.isDirectory
                  ? null
                  : Text(formatSize(f.size ?? 0),
                      style: const TextStyle(fontSize: 12)),
            ),
            if (!f.isDirectory)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('下载'),
                onTap: () => Navigator.of(ctx).pop('download'),
              ),
            if (!f.isDirectory && isVideoFile(f.name))
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('在线播放'),
                onTap: () => Navigator.of(ctx).pop('play'),
              ),
            if (controller.isAdmin)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Colors.redAccent),
                title: const Text('删除',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'download') controller.downloadFile(f);
    if (action == 'play') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
            controller: controller, entry: f),
      ));
    }
    if (action == 'delete') _confirmDelete(context, controller, f);
  }

  /// 删除确认对话框（主目录仅管理员有删除权限）
  Future<void> _confirmDelete(
      BuildContext context, AppController controller, FileEntry f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: Text(
            '确定删除「${f.name}」吗？${f.isDirectory ? '目录将递归删除。' : ''}此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) controller.deleteFile(f);
  }
}

class _FileTile extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onLongPress;

  const _FileTile(
      {required this.entry,
      required this.onTap,
      this.onPlay,
      this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
        color: entry.isDirectory ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
        size: 32,
      ),
      title: Text(entry.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: entry.isDirectory
          ? null
          : Text(formatSize(entry.size ?? 0),
              style: const TextStyle(fontSize: 12)),
      trailing: entry.isDirectory
          ? const Icon(Icons.chevron_right)
          : (onPlay != null
              ? IconButton(
                  icon: const Icon(Icons.play_circle_fill,
                      color: Color(0xFF38BDF8),
                      size: 32),
                  tooltip: '在线播放',
                  onPressed: onPlay,
                )
              : null),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

class _DownloadBanner extends StatelessWidget {
  final AppController controller;

  const _DownloadBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    final total = controller.activeDownloadSize;
    final done = controller.activeDownloadBytes;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.download, size: 18, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('正在下载: ${controller.activeDownloadName}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (controller.connectionType.isNotEmpty) ...[  // 下载时显示当前传输方式
                  const SizedBox(width: 6),
                  _ConnChip(label: controller.connTypeLabel),
                ],
                const SizedBox(width: 8),
                Text('${formatSize(done)} / ${formatSize(total)}',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                // 手动停止下载：发送中止消息 + 清理 .part（防误触样式与删除一致）
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Colors.redAccent, size: 20),
                  tooltip: '停止下载',
                  onPressed: () => controller.stopDownload(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress, minHeight: 6),
          ],
        ),
      ),
    );
  }
}

/// 上传页签
class _UploadTab extends StatefulWidget {
  final AppController controller;

  const _UploadTab({required this.controller});

  @override
  State<_UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<_UploadTab> {
  final List<PlatformFile> _picked = [];
  String? _lastConflictShown; // 已弹窗的冲突文件，避免重复弹窗
  bool _applyAll = false; // 对本次所有重名文件同样处理（弹窗内勾选）
  bool _processingPick = false; // 文件选择器正在读取所选文件（大文件耗时较长）

  /// 选择文件：支持多次追加（自动去重），避免系统选择器单选限制
  /// Android 上 file_picker 每次选择会复制到缓存目录、path 每次都不同，
  /// 故用 name + size 判断重复（同一文件大小必然相同）
  Future<void> _pickFiles() async {
    // 大文件选择后需复制到缓存目录，先显示处理中提示，避免用户误以为没选上
    setState(() => _processingPick = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) {
        AppLog.i('upload', '文件选择器取消，未选择文件');
        return;
      }
      var added = 0;
      setState(() {
        for (final f in result.files) {
          final dup = _picked.any(
              (p) => p.name == f.name && p.size == f.size);
          if (!dup) {
            _picked.add(f);
            added++;
          }
        }
      });
      AppLog.i('upload',
          '选择文件: 新选$added个(已选${_picked.length}个), 合计${_picked.fold<int>(0, (s, f) => s + f.size)}B');
    } finally {
      if (mounted) setState(() => _processingPick = false);
    }
  }

  /// 选择上传目标目录（电脑端共享目录下的子目录）
  Future<void> _pickUploadDir() async {
    widget.controller.refreshUploadDirs();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _UploadDirDialog(controller: widget.controller),
    );
  }

  /// 重名冲突弹窗（由 controller.pendingConflict 触发）
  void _checkConflict(AppController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final req = controller.pendingConflict;
      if (req == null || req.fileName == _lastConflictShown) return;
      _lastConflictShown = req.fileName;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('文件名重复'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    '电脑端已存在同名文件「${req.fileName}」\n请选择处理方式：'),
                CheckboxListTile(
                  value: _applyAll,
                  onChanged: (v) =>
                      setDialogState(() => _applyAll = v ?? false),
                  title: const Text('对本次上传的其他重名文件同样处理'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  controller.resolveConflict('skip', applyAll: _applyAll);
                  Navigator.of(ctx).pop();
                },
                child: const Text('跳过'),
              ),
              TextButton(
                onPressed: () {
                  controller.resolveConflict('rename', applyAll: _applyAll);
                  Navigator.of(ctx).pop();
                },
                child: const Text('另存为'),
              ),
              FilledButton(
                onPressed: () {
                  controller
                      .resolveConflict('overwrite', applyAll: _applyAll);
                  Navigator.of(ctx).pop();
                },
                child: const Text('覆盖'),
              ),
            ],
          ),
        ),
      ).then((_) {
        // 弹窗关闭后重置去重标记：同一批中多个同名文件需依次弹窗决策
        _lastConflictShown = null;
        _applyAll = false;
      });
    });
  }

  Future<void> _upload() async {
    if (_picked.isEmpty) return;
    final ok = await widget.controller.startUpload(_picked);
    if (!mounted) return;
    final fail = _picked.length - ok;
    setState(() => _picked.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fail > 0
              ? '上传完成: $ok 个成功, $fail 个失败(见传输记录)'
              : '上传完成: $ok 个文件已发送',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final busy = controller.uploading;
    _checkConflict(controller);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _pickUploadDir,
                icon: const Icon(Icons.folder_copy_outlined),
                label: Text(
                  '上传到: ${controller.uploadDirPath.isEmpty ? '远程电脑' : controller.uploadDirPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy || _processingPick ? null : _pickFiles,
                icon: const Icon(Icons.attach_file),
                label: Text(busy || _processingPick
                    ? '正在读取所选文件…'
                    : '选择要上传的文件'),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
              if (_processingPick)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: const [
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('正在读取所选文件，大文件需要一点时间，请稍候…',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                    ],
                  ),
                ),
              if (_picked.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '已选 ${_picked.length} 个文件',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => _picked.clear()),
                      child: const Text('清空'),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < _picked.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.description_outlined,
                                  size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_picked[i].name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                              Text(formatSize(_picked[i].size),
                                  style: const TextStyle(fontSize: 12)),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                visualDensity: VisualDensity.compact,
                                tooltip: '移除',
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                        () => _picked.removeAt(i)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '可再次点「选择要上传的文件」继续添加',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : _upload,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload),
                  label: Text(busy
                      ? '上传中...'
                      : '开始上传 (${_picked.length})'),
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
                if (busy && controller.connectionType.isNotEmpty) ...[  // 上传时显示当前传输方式
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('当前传输方式:',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(width: 6),
                      _ConnChip(label: controller.connTypeLabel),
                    ],
                  ),
                ],
              ],
              if (controller.errorMessage != null &&
                  controller.errorMessage!.contains('保存'))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    controller.errorMessage!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _TransfersTab(controller: controller, filter: 'upload'),
        ),
      ],
    );
  }
}

/// 上传目标目录选择对话框（浏览电脑端共享目录树）
class _UploadDirDialog extends StatefulWidget {
  final AppController controller;

  const _UploadDirDialog({required this.controller});

  @override
  State<_UploadDirDialog> createState() => _UploadDirDialogState();
}

class _UploadDirDialogState extends State<_UploadDirDialog> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final segments = controller.uploadDirPath.isEmpty
        ? <String>[]
        : controller.uploadDirPath.split('/');

    return AlertDialog(
      title: const Text('选择上传目录'),
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: [
              // 路径面包屑
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    ActionChip(
                      label: const Text('远程电脑'),
                      onPressed: () => controller.navigateUploadDir(-1),
                    ),
                    for (var i = 0; i < segments.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: ActionChip(
                          label: Text(segments[i]),
                          onPressed: () => controller.navigateUploadDir(i),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // 子目录列表
              Expanded(
                child: controller.uploadDirLoading
                    ? const Center(child: CircularProgressIndicator())
                    : controller.uploadDirs.isEmpty
                        ? const Center(
                            child: Text('此目录下没有子目录',
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            itemCount: controller.uploadDirs.length,
                            itemBuilder: (context, i) {
                              final d = controller.uploadDirs[i];
                              if (!d.isDirectory) {
                                return const SizedBox.shrink();
                              }
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.folder,
                                    color: Color(0xFFF59E0B)),
                                title: Text(d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                onTap: () =>
                                    controller.openUploadDir(d),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
              '上传到此目录 (${segments.isEmpty ? '远程电脑' : controller.uploadDirPath})'),
        ),
      ],
    );
  }
}

/// 传输记录页签
class _TransfersTab extends StatelessWidget {
  final AppController controller;
  final String? filter;

  const _TransfersTab({required this.controller, this.filter});

  @override
  Widget build(BuildContext context) {
    final items = filter == null
        ? controller.transfers
        : controller.transfers.where((t) => t.direction == filter).toList();

    if (items.isEmpty) {
      return const _MessageView(
        icon: Icons.history,
        text: '暂无传输记录',
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        // 显示本次传输时的连接方式（记录快照）：已完成的记录固定显示传输时的方式；
        // 进行中且探测尚未完成（unknown）时回退显示当前方式
        String? connLabel;
        if (item.connType == 'relay') {
          connLabel = '服务器中转';
        } else if (item.connType == 'direct') {
          connLabel = 'P2P直连';
        } else if (item.status == 'transferring') {
          connLabel = controller.connTypeLabel;
        }
        return _TransferTile(item: item, connLabel: connLabel);
      },
    );
  }
}

class _TransferTile extends StatelessWidget {
  final TransferItem item;
  final String? connLabel; // 传输时的连接方式（直连/服务器中转）

  const _TransferTile({required this.item, this.connLabel});

  @override
  Widget build(BuildContext context) {
    final isUpload = item.direction == 'upload';
    final done = item.status == 'done';
    final error = item.status == 'error';
    final skipped = item.status == 'skipped';

    return ListTile(
      leading: Icon(
        skipped
            ? Icons.skip_next
            : isUpload
                ? Icons.upload
                : Icons.download,
        color: error
            ? Colors.redAccent
            : done
                ? Colors.green
                : skipped
                    ? Colors.orange
                    : Colors.blue,
      ),
      title: Row(
        children: [
          Expanded(
            child:
                Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          // 连接方式彩色徽标（醒目标题行）：绿=点对点直连 橙=服务器中转
          if (connLabel != null && connLabel!.isNotEmpty) ...[
            const SizedBox(width: 6),
            _ConnChip(label: connLabel!),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (!done && !error && !skipped)
            LinearProgressIndicator(value: item.progress, minHeight: 4),
          const SizedBox(height: 4),
          Text(
            skipped
                ? '已跳过（电脑端存在同名文件）'
                : '${formatSize(item.transferred)} / ${formatSize(item.total)}'
                    '${item.speed.isNotEmpty ? '  ${item.speed}' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      trailing: Icon(
        error
            ? Icons.error_outline
            : done
                ? Icons.check_circle
                : skipped
                    ? Icons.remove_circle_outline
                    : Icons.sync,
        size: 20,
        color: error
            ? Colors.redAccent
            : done
                ? Colors.green
                : skipped
                    ? Colors.orange
                    : Colors.grey,
      ),
    );
  }
}

/// 连接方式徽标：绿=点对点直连 橙=服务器中转（传输记录/下载横幅/上传中复用）
class _ConnChip extends StatelessWidget {
  final String label;

  const _ConnChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final direct = label.contains('直连');
    final color = direct ? Colors.green.shade700 : Colors.orange.shade800;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (direct ? Colors.green : Colors.orange).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(direct ? Icons.link : Icons.hub,
              size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用提示视图
class _MessageView extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MessageView({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
