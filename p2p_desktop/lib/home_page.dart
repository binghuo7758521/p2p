import 'package:flutter/material.dart';

import 'dart:io';

import 'app_log.dart';
import 'connect_page.dart';
import 'host_controller.dart';
import 'models.dart';
import 'share_manage_page.dart';
import 'silent_updater.dart';
import 'update_check.dart';
import 'users_manage_page.dart';
import 'version.dart';

/// 电脑端主界面：共享目录浏览 + 传输记录
class HomePage extends StatefulWidget {
  final HostController controller;

  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  /// 启动时检查升级：服务器有新版本时弹窗提示（每次启动检查一次）
  ///
  /// 升级检查放在主页面而非连接页：连接页可能被「管理员直进主页」
  /// pushReplacement 销毁，await 返回后 mounted=false 会跳过弹窗
  Future<void> _checkUpdate() async {
    final info = await checkDesktopUpdate();
    if (!mounted || info == null || !info.needUpdate) return;
    final hasMd5 = info.md5 != null && info.md5!.isNotEmpty;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: Text('发现新版本 v${info.latest}'),
        content: Text(
          '当前版本 v$appVersion\n\n${info.notes}\n\n'
          '升级将自动下载、校验并重启，全程无需手动操作',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(ctx).pop();
              if (info.url == null) return;
              if (hasMd5) {
                _runSilentUpgrade(info);
              } else {
                // 服务器未提供校验值：回退手动浏览器下载
                openDownloadUrl(info.url!);
                _showUpdateError('服务器未提供升级包校验信息，已为你打开下载页面，'
                    '请手动下载并解压覆盖程序目录');
              }
            },
            icon: const Icon(Icons.download, size: 18),
            label: const Text('立即升级'),
          ),
        ],
      ),
    );
  }

  /// 静默升级：进度对话框 + 下载/校验/解压/重启编排
  Future<void> _runSilentUpgrade(UpdateInfo info) async {
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('正在准备升级…');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: const Text('正在升级'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, p, _) => LinearProgressIndicator(value: p),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, _) => Text(s, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );

    final ok = await runSilentUpgrade(
      downloadUrl: info.url!,
      expectedMd5: info.md5,
      onPhase: (phase, p, message) {
        progress.value = p;
        status.value = message;
      },
    );

    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭进度对话框
    if (ok) {
      // 升级已编排：立即退出主程序，由 update.bat 完成替换与重启
      AppLog.i('update', '静默升级成功，主程序退出');
      exit(0);
    }
    if (info.url != null) openDownloadUrl(info.url!);
    _showUpdateError('自动升级失败，已为你打开下载页面，'
        '请手动下载并解压覆盖程序目录');
  }

  /// 升级失败提示
  void _showUpdateError(String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: Colors.red),
        title: const Text('升级失败'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
                controller.state == HostState.peerConnected;
            final waiting =
                controller.state == HostState.registered;
            final offline = controller.state == HostState.offline;
            // 在线用户（第一个为管理员）
            final onlineUsers = controller.users.values
                .where((u) => u.online)
                .toList();
            final onlineDesc = onlineUsers.isEmpty
                ? '未连接'
                : '已连接 ${onlineUsers.length} 台手机'
                    '${onlineUsers.length == 1 && onlineUsers.first.isAdmin ? '（管理员）' : ''}'
                    ' · 配对码 ${controller.pairCode}';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('P2P 文件助手 - 电脑端',
                    style: const TextStyle(fontSize: 18)),
                Text(
                  offline
                      ? '离线（不接受手机连接）'
                      : connected
                          ? onlineDesc
                          : waiting
                              ? '等待手机连接 · 配对码 ${controller.pairCode}'
                              : '未连接',
                  style: TextStyle(
                      fontSize: 12,
                      color: offline
                          ? Colors.grey
                          : connected
                              ? Colors.green
                              : waiting
                                  ? Colors.orange
                                  : Colors.redAccent),
                ),
                if (connected) ...[const SizedBox(height: 2), _ConnBadge(controller: controller)],
              ],
            );
          },
        ),
        actions: [
          // 备注名称：设置本机名称，手机端选择连接时展示
          IconButton(
            tooltip: '备注名称（手机端显示）',
            icon: const Icon(Icons.edit_note),
            onPressed: () async {
              final ctrl = TextEditingController(
                  text: controller.deviceName == '电脑-桌面'
                      ? ''
                      : controller.deviceName);
              final name = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('备注名称'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('设置后手机端在选择连接时会显示此名称\n'
                          '（例如：办公室电脑、家里电脑）',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: ctrl,
                        autofocus: true,
                        maxLength: 20,
                        decoration: const InputDecoration(
                          labelText: '名称',
                          hintText: '不填则显示默认名',
                          border: OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                        child: const Text('保存')),
                  ],
                ),
              );
              if (name == null || !context.mounted) return;
              if (name.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('名称为空，未修改')));
                return;
              }
              await controller.setDeviceName(name);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('名称已保存为「${name.trim()}」，重新连接中…')));
            },
          ),
          ListenableBuilder(
            listenable: controller,
            // 共享文件夹管理：注册后即可管理（无手机连接时也可
            // 提前设置共享，配置本地持久化 + 服务器同步；仅断网隐藏）
            builder: (context, _) =>
                controller.state != HostState.idle
                    ? IconButton(
                        tooltip: '共享文件夹管理',
                        icon: const Icon(Icons.folder_shared),
                        onPressed: () {
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  ShareManagePage(controller: controller)));
                        },
                      )
                    : const SizedBox.shrink(),
          ),
          ListenableBuilder(
            listenable: controller,
            // 手机端管理：注册后即可查看（含离线用户记录，可删除）
            builder: (context, _) =>
                controller.state != HostState.idle
                    ? IconButton(
                        tooltip: '手机端管理',
                        icon: const Icon(Icons.people_alt_outlined),
                        onPressed: () {
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) =>
                                  UsersManagePage(controller: controller)));
                        },
                      )
                    : const SizedBox.shrink(),
          ),
          // 在线/离线开关：离线=不接受手机端连接；在线=接受（默认）
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Tooltip(
              message: controller.isOnline ? '在线，点击切换离线' : '离线，点击切换在线',
              child: Switch(
                value: controller.isOnline,
                onChanged: (v) => controller.setOnline(v),
              ),
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.state == HostState.lost) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text(controller.errorMessage ?? '连接已断开',
                      style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () async {
                      await controller.disconnect();
                      if (!context.mounted) return;
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(
                            builder: (_) =>
                                ConnectPage(controller: controller)),
                      );
                    },
                    child: const Text('返回连接页'),
                  ),
                ],
              ),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左侧：共享目录
              SizedBox(
                width: 340,
                child: _DirPanel(controller: controller),
              ),
              const VerticalDivider(width: 1),
              // 右侧：传输记录
              Expanded(
                child: _TransfersPanel(controller: controller),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 共享目录浏览面板
class _DirPanel extends StatelessWidget {
  final HostController controller;

  const _DirPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final segs = controller.localPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.folder, size: 18, color: Color(0xFFF59E0B)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controller.myComputerMode
                      ? '我的电脑'
                      : (controller.sharedDir?.path ?? '未选择共享目录'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: controller.myComputerMode ? '选择其他目录' : '恢复默认',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: controller.myComputerMode
                    ? () => controller.pickSharedDir()
                    : () => controller.restoreMyComputer(),
              ),
            ],
          ),
        ),
        // 面包屑
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              ActionChip(
                label: Text(controller.myComputerMode ? '我的电脑' : '根目录'),
                visualDensity: VisualDensity.compact,
                onPressed: () => controller.navigateLocal(-1),
              ),
              for (var i = 0; i < segs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ActionChip(
                    label: Text(segs[i]),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => controller.navigateLocal(i),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 文件列表
        Expanded(
          child: controller.localFiles.isEmpty
              ? const Center(
                  child: Text('此目录为空',
                      style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: controller.localFiles.length,
                  itemBuilder: (context, i) {
                    final f = controller.localFiles[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        f.isDirectory
                            ? Icons.folder
                            : Icons.insert_drive_file,
                        color: f.isDirectory
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF38BDF8),
                        size: 24,
                      ),
                      title: Text(f.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: f.isDirectory
                          ? null
                          : Text(_fmtSize(f.size ?? 0),
                              style: const TextStyle(fontSize: 11)),
                      onTap: f.isDirectory
                          ? () => controller.openLocalDir(f)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 传输记录面板
class _TransfersPanel extends StatelessWidget {
  final HostController controller;

  const _TransfersPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    final items = controller.transfers.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.swap_vert, size: 18, color: Colors.blue),
              SizedBox(width: 8),
              Text('传输记录',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history, size: 56, color: Colors.grey),
                      SizedBox(height: 8),
                      Text('暂无传输记录',
                          style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => _TransferTile(
                      item: items[i], connLabel: controller.connTypeLabel),
                ),
        ),
      ],
    );
  }
}

class _ConnBadge extends StatelessWidget {
  final HostController controller;

  const _ConnBadge({required this.controller});

  @override
  Widget build(BuildContext context) {
    final relay = controller.connTypeLabel.contains('服务器中转');
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

class _TransferTile extends StatelessWidget {
  final TransferItem item;
  final String connLabel;

  const _TransferTile({required this.item, required this.connLabel});

  @override
  Widget build(BuildContext context) {
    final isUpload = item.direction == 'upload';
    final done = item.status == 'done';
    final error = item.status == 'error';
    final icon = isUpload ? Icons.upload : Icons.download;
    final direct = connLabel.contains('直连');

    return ListTile(
      leading: Icon(
        icon,
        color: error
            ? Colors.redAccent
            : done
                ? Colors.green
                : Colors.blue,
      ),
      title: Text(item.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (!done && !error)
            LinearProgressIndicator(value: item.progress, minHeight: 4),
          const SizedBox(height: 4),
          Text(
            '${item.clientName.isNotEmpty ? '${item.clientName} · ' : ''}'
            '${isUpload ? '手机 → 电脑' : '电脑 → 手机'}  '
            '${_fmtSize(item.transferred)} / ${_fmtSize(item.total)}'
            '${item.speed.isNotEmpty ? '  ${item.speed}' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 2),
          // 连接方式：P2P直连(绿) / 服务器中转(橙)，直观告知用户传输通道
          Row(
            children: [
              Icon(
                direct ? Icons.link : Icons.hub,
                size: 12,
                color: direct ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 4),
              Text(
                connLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: direct ? Colors.green : Colors.orange,
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: Icon(
        error
            ? Icons.error_outline
            : done
                ? Icons.check_circle
                : Icons.sync,
        size: 20,
        color: error
            ? Colors.redAccent
            : done
                ? Colors.green
                : Colors.grey,
      ),
    );
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1073741824) {
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}
