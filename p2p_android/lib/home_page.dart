import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'connect_page.dart';
import 'models.dart';
import 'protocol.dart';
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
                Text('P2P 文件助手', style: const TextStyle(fontSize: 18)),
                Text(
                  connected
                      ? '已连接: ${controller.hostName ?? '电脑'}'
                      : '未连接',
                  style: TextStyle(
                      fontSize: 12,
                      color: connected ? Colors.green : Colors.redAccent),
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
                    builder: (_) => ConnectPage(
                        controller: controller, autoConnect: false)),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.state == ConnectState.lost) {
            return _LostView(controller: controller);
          }
          return IndexedStack(
            index: _tab,
            children: [
              _BrowseTab(controller: controller),
              _UploadTab(controller: controller),
              _TransfersTab(controller: controller),
            ],
          );
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (i == 0) controller.requestFileList();
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: '浏览'),
          NavigationDestination(
              icon: Icon(Icons.upload_outlined),
              selectedIcon: Icon(Icons.upload),
              label: '上传'),
          NavigationDestination(
              icon: Icon(Icons.swap_vert_outlined),
              selectedIcon: Icon(Icons.swap_vert),
              label: '传输'),
        ],
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
              await controller.disconnect();
              if (!context.mounted) return;
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                    builder: (_) => ConnectPage(
                        controller: controller, autoConnect: false)),
              );
            },
            child: const Text('返回连接页'),
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

    return Column(
      children: [
        // 路径面包屑
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            children: [
              ActionChip(
                label: const Text('根目录'),
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
        Expanded(child: _buildList(controller)),
      ],
    );
  }

  Widget _buildList(AppController controller) {
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
}

class _FileTile extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onPlay;

  const _FileTile({required this.entry, required this.onTap, this.onPlay});

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
                      color: Color(0xFF38BDF8), size: 32),
                  tooltip: '在线播放',
                  onPressed: onPlay,
                )
              : null),
      onTap: onTap,
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
                Text('${formatSize(done)} / ${formatSize(total)}',
                    style: const TextStyle(fontSize: 12)),
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

  /// 选择文件：支持多次追加（自动去重），避免系统选择器单选限制
  /// Android 上 file_picker 每次选择会复制到缓存目录、path 每次都不同，
  /// 故用 name + size 判断重复（同一文件大小必然相同）
  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    setState(() {
      for (final f in result.files) {
        final dup = _picked.any(
            (p) => p.name == f.name && p.size == f.size);
        if (!dup) _picked.add(f);
      }
    });
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
                  '上传到: ${controller.uploadDirPath.isEmpty ? '根目录' : controller.uploadDirPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : _pickFiles,
                icon: const Icon(Icons.attach_file),
                label: const Text('选择要上传的文件'),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
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
                      label: const Text('根目录'),
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
              '上传到此目录 (${segments.isEmpty ? '根目录' : controller.uploadDirPath})'),
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
      itemBuilder: (context, i) => _TransferTile(item: items[i]),
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
      title: Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
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
