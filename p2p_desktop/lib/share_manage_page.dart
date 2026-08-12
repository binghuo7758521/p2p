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
              final targetName = s.targetPhone != null
                  ? '手机号 ${s.targetPhone}'
                  : (s.isPublic ? '二维码（扫码加入）' : '指定设备');
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
                                        : (bound ? '已生效' : '待对方登录生效')),
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

  /// 新增共享对话框：选择文件夹 + 分享方式（手机号/二维码）+ 权限
  Future<void> _openCreateDialog() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要共享的文件夹',
    );
    if (path == null || !mounted) return;

    final mode = ValueNotifier<int>(1); // 0=指定手机号 1=生成二维码
    final phoneCtrl = TextEditingController();
    final perms = <String>{'download', 'upload', 'delete'};

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
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                        value: 0,
                        label: Text('指定手机号'),
                        icon: Icon(Icons.phone_android, size: 16)),
                    ButtonSegment(
                        value: 1,
                        label: Text('生成二维码'),
                        icon: Icon(Icons.qr_code_2, size: 16)),
                  ],
                  selected: {mode.value},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => mode.value = s.first),
                ),
                const SizedBox(height: 10),
                if (mode.value == 0)
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    maxLength: 11,
                    decoration: const InputDecoration(
                      isDense: true,
                      counterText: '',
                      prefixIcon: Icon(Icons.phone_android, size: 18),
                      hintText: '输入对方注册手机号',
                      border: OutlineInputBorder(),
                    ),
                  )
                else
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
                        Icon(Icons.info_outline, size: 18),
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
                const Text('用户对该文件夹的权限：',
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
              final phone = phoneCtrl.text.trim();
              if (mode.value == 0 && phone.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('请输入对方注册手机号')),
                );
                return;
              }
              Navigator.of(ctx).pop(true);
              final share = widget.controller.createShare(
                phone: mode.value == 0 ? phone : null,
                folder: path,
                perms: perms.toList(),
              );
              if (share == null) {
                _toast('创建共享失败');
                return;
              }
              if (share.isPublic) {
                _showQr(share);
              } else {
                _toast('已共享「${share.name}」'
                    '${share.targetDeviceId != null ? '，对方已可访问' : '，待对方登录后生效'}');
              }
            },
            child: Text(mode.value == 0 ? '确认共享' : '生成共享二维码'),
          ),
        ],
      ),
    );
    phoneCtrl.dispose();
    mode.dispose();
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
