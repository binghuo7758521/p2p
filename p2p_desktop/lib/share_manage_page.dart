import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'host_controller.dart';

/// 电脑端共享文件夹管理：查看全部共享、新增、删除、修改权限、查看二维码
class ShareManagePage extends StatefulWidget {
  final HostController controller;

  const ShareManagePage({super.key, required this.controller});

  @override
  State<ShareManagePage> createState() => _ShareManagePageState();
}

class _ShareManagePageState extends State<ShareManagePage> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('共享文件夹管理'),
        actions: [
          IconButton(
            tooltip: '新增共享',
            icon: const Icon(Icons.add),
            onPressed: _openCreateDialog,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final shares = controller.shareList;
          if (shares.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.folder_shared, size: 64, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text('暂无共享文件夹',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: _openCreateDialog,
                    icon: const Icon(Icons.add),
                    label: const Text('新增共享'),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: shares.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final s = shares[i];
              // v5.9+ 不再按手机号定向共享：历史 targetPhone 数据统一展示为定向共享
              final targetName =
                  s.isPublic ? '二维码（扫码加入）' : '定向共享';
              final bound = s.targetDeviceId != null || s.isPublic;
              return Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.folder, color: Color(0xFFF59E0B)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(s.folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _Chip(
                                    icon: Icons.person_outline,
                                    text: targetName),
                                _Chip(
                                    icon: Icons.security,
                                    text: s.isPublic
                                        ? '公开'
                                        : (bound ? '已生效' : '待对方扫码加入')),
                                if (s.canDownload)
                                  const _Chip(
                                      icon: Icons.download, text: '下载'),
                                if (s.canUpload)
                                  const _Chip(icon: Icons.upload, text: '上传'),
                                if (s.canDelete)
                                  const _Chip(icon: Icons.delete, text: '删除'),
                              ],
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '操作',
                        onSelected: (v) {
                          switch (v) {
                            case 'qr':
                              _showQr(s);
                            case 'remark':
                              _editRemark(s);
                            case 'perms':
                              _editPerms(s);
                            case 'del':
                              _confirmDelete(s);
                          }
                        },
                        itemBuilder: (_) => [
                          if (s.isPublic)
                            const PopupMenuItem(
                                value: 'qr', child: Text('查看共享二维码')),
                          const PopupMenuItem(
                              value: 'remark', child: Text('备注名称')),
                          const PopupMenuItem(
                              value: 'perms', child: Text('修改权限')),
                          const PopupMenuItem(
                              value: 'del', child: Text('删除共享')),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 编辑共享备注名称（留空恢复为文件夹末段，同步到手机端“共享给我的”展示）
  void _editRemark(ShareConfig share) {
    final ctrl = TextEditingController(text: share.remark);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('备注名称 - ${share.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 30,
              decoration: const InputDecoration(
                labelText: '备注名称（留空则显示文件夹名）',
                hintText: '例如：工作资料',
              ),
            ),
            const SizedBox(height: 4),
            Text(share.folder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              widget.controller.setShareRemark(share.token, ctrl.text);
              Navigator.of(ctx).pop();
              _toast('备注已更新');
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 共享权限勾选对话框
  void _editPerms(ShareConfig share) {
    final perms = Set<String>.of(share.perms);
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('修改权限 - ${share.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (perm, label) in [
                ('download', '下载'),
                ('upload', '上传'),
                ('delete', '删除'),
              ])
                CheckboxListTile(
                  value: perms.contains(perm),
                  title: Text(label),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      perms.add(perm);
                    } else {
                      perms.remove(perm);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                widget.controller.updateSharePerms(share.token, perms.toList());
                Navigator.of(ctx).pop();
                _toast('权限已更新');
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 删除共享确认
  void _confirmDelete(ShareConfig share) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除共享'),
        content: Text('确定删除「${share.name}」的共享吗？\n所有已加入用户将无法再访问该文件夹。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok == true && mounted) {
        widget.controller.removeShare(share.token);
        _toast('已删除共享「${share.name}」');
      }
    });
  }

  /// 共享二维码弹窗（公开共享）
  void _showQr(ShareConfig share) {
    final c = widget.controller;
    final qrData =
        'p2p:${c.serverUrl}|${c.pairCode}|${share.token}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('共享二维码 - ${share.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: qrData, size: 220),
            const SizedBox(height: 12),
            const Text('对方扫码加入后即可看到此共享文件夹',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  /// 新增共享对话框：选择文件夹 + 公开二维码方式 + 权限（v5.9+ 去手机号）
  /// 指定设备共享请用手机端管理页（管理员操作）
  Future<void> _openCreateDialog() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要共享的文件夹',
    );
    if (path == null || !mounted) return;

    final perms = <String>{'download', 'upload', 'delete'};
    final remarkCtrl = TextEditingController(
        text: path.split(RegExp(r'[/\\]')).last); // 默认预填文件夹末段

    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新增共享'),
        content: SizedBox(
          width: 420,
          child: StatefulBuilder(
            builder: (ctx, setState) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.folder, size: 18, color: Color(0xFFF59E0B)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx)
                        .colorScheme
                        .secondaryContainer
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.qr_code_2, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '生成二维码后，对方扫码加入才能看到此共享文件夹',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: remarkCtrl,
                  maxLength: 30,
                  decoration: const InputDecoration(
                    labelText: '备注名称（对方看到的名称，可修改）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 4),
                const Text('权限设置：',
                    style: TextStyle(fontSize: 13)),
                Row(
                  children: [
                    for (final (perm, label) in [
                      ('download', '下载'),
                      ('upload', '上传'),
                      ('delete', '删除'),
                    ])
                      Expanded(
                        child: CheckboxListTile(
                          value: perms.contains(perm),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(label),
                          controlAffinity:
                              ListTileControlAffinity.leading,
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              perms.add(perm);
                            } else {
                              perms.remove(perm);
                            }
                          }),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop(true);
              final share = widget.controller.createShare(
                folder: path,
                perms: perms.toList(),
                remark: remarkCtrl.text,
              );
              if (share == null) {
                _toast('创建共享失败');
                return;
              }
              _showQr(share);
            },
            child: const Text('生成共享二维码'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }
}

/// 小标签
class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Chip({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.grey),
          const SizedBox(width: 3),
          Text(text, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
