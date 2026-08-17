import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'download_banner.dart';
import 'models.dart';
import 'protocol.dart';

/// 共享目录浏览页：浏览 / 下载 / 上传 / 删除（按权限显示操作）
class ShareBrowsePage extends StatefulWidget {
  final AppController controller;

  const ShareBrowsePage({super.key, required this.controller});

  @override
  State<ShareBrowsePage> createState() => _ShareBrowsePageState();
}

class _ShareBrowsePageState extends State<ShareBrowsePage> {
  bool _picking = false;

  /// 选择文件并上传到当前共享目录
  Future<void> _pickAndUpload() async {
    final controller = widget.controller;
    final share = controller.activeShare;
    if (share == null || !share.canUpload) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final ok = await controller.startUpload(result.files, share: share);
      if (!mounted) return;
      final fail = result.files.length - ok;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(fail > 0
            ? '上传完成: $ok 个成功, $fail 个失败(见传输记录)'
            : '上传完成: $ok 个文件已发送'),
        duration: const Duration(seconds: 2),
      ));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _confirmDelete(FileEntry f) async {
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
    if (ok == true) widget.controller.deleteFile(f);
  }

  /// 显示操作结果提示（共享附加/删除等）
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

  String _permsLabel(ShareEntry? s) {
    if (s == null) return '';
    final list = <String>[
      if (s.canDownload) '下载',
      if (s.canUpload) '上传',
      if (s.canDelete) '删除',
    ];
    return list.isEmpty ? '无操作权限' : '权限: ${list.join(' / ')}';
  }

  Widget _breadcrumbs(AppController controller) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          ActionChip(
            label: const Text('远程电脑'),
            onPressed: () => controller.navigateShareTo(-1),
          ),
          for (var i = 0; i < controller.shareCrumbs.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ActionChip(
                label: Text(controller.shareCrumbs[i],
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () => controller.navigateShareTo(i),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(AppController controller) {
    final share = controller.activeShare;
    if (controller.shareLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.shareError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(controller.shareError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }
    if (controller.shareFiles.isEmpty) {
      return const Center(
          child: Text('此目录为空', style: TextStyle(color: Colors.grey)));
    }
    return RefreshIndicator(
      onRefresh: () async => controller.refreshShareList(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: controller.shareFiles.length,
        itemBuilder: (context, i) {
          final f = controller.shareFiles[i];
          final canDelete = share?.canDelete ?? false;
          return ListTile(
            leading: Icon(
              f.isDirectory ? Icons.folder : Icons.insert_drive_file,
              color: f.isDirectory
                  ? const Color(0xFFF59E0B)
                  : const Color(0xFF38BDF8),
              size: 32,
            ),
            title: Text(f.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: f.isDirectory
                ? null
                : Text(formatSize(f.size ?? 0),
                    style: const TextStyle(fontSize: 12)),
            trailing: f.isDirectory
                ? const Icon(Icons.chevron_right)
                : ((share?.canDownload ?? false)
                    ? const Icon(Icons.download,
                        color: Color(0xFF38BDF8))
                    : null),
            // 删除等危险操作不常显在列表中（防误触）：长按列表项弹出删除确认
            onLongPress: canDelete ? () => _confirmDelete(f) : null,
            onTap: () {
              if (f.isDirectory) {
                controller.openShareDir(f);
              } else if (share?.canDownload ?? false) {
                controller.downloadShareFile(f);
              }
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          controller.closeShare();
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final s = controller.activeShare;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('共享目录: ${s?.name ?? ''}',
                      style: const TextStyle(fontSize: 17)),
                  Text(_permsLabel(s),
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              );
            },
          ),
          actions: [
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final canUpload = controller.activeShare?.canUpload ?? false;
                return canUpload
                    ? IconButton(
                        tooltip: '上传文件到此共享目录',
                        icon: _picking
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.upload),
                        onPressed: _picking ? null : _pickAndUpload,
                      )
                    : const SizedBox.shrink();
              },
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            _showActionMessage(controller);
            return Column(
              children: [
                _breadcrumbs(controller),
                const Divider(height: 1),
                // v5.24+：共享目录下载进度横幅（与主页一致，含实时速度/停止）
                if (controller.activeDownloadName != null)
                  DownloadBanner(controller: controller),
                // v5.25+：共享目录上传进度横幅（上传中即时反馈，含实时速度/停止）
                if (controller.activeUploadName != null)
                  UploadBanner(controller: controller),
                Expanded(child: _buildList(controller)),
              ],
            );
          },
        ),
      ),
    );
  }
}
