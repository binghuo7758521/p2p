import 'package:flutter/material.dart';

import 'connect_page.dart';
import 'host_controller.dart';
import 'models.dart';

/// 电脑端主界面：共享目录浏览 + 传输记录
class HomePage extends StatefulWidget {
  final HostController controller;

  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('P2P 文件助手 - 电脑端',
                    style: const TextStyle(fontSize: 18)),
                Text(
                  connected
                      ? '已连接: ${controller.clientName ?? '手机'} · 配对码 ${controller.pairCode}'
                      : waiting
                          ? '等待手机连接 · 配对码 ${controller.pairCode}'
                          : '未连接',
                  style: TextStyle(
                      fontSize: 12,
                      color: connected
                          ? Colors.green
                          : waiting
                              ? Colors.orange
                              : Colors.redAccent),
                ),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            tooltip: '断开连接',
            icon: const Icon(Icons.link_off),
            onPressed: () async {
              await controller.disconnect();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                    builder: (_) => ConnectPage(controller: controller)),
              );
            },
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
                  itemBuilder: (context, i) =>
                      _TransferTile(item: items[i]),
                ),
        ),
      ],
    );
  }
}

class _TransferTile extends StatelessWidget {
  final TransferItem item;

  const _TransferTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final isUpload = item.direction == 'upload';
    final done = item.status == 'done';
    final error = item.status == 'error';
    final icon = isUpload ? Icons.upload : Icons.download;

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
            '${isUpload ? '手机 → 电脑' : '电脑 → 手机'}  '
            '${_fmtSize(item.transferred)} / ${_fmtSize(item.total)}'
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
