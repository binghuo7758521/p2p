import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'app_controller.dart';
import 'app_log.dart';
import 'models.dart';

/// 管理员用户管理页：查看用户、共享文件夹管理（新增/二维码）、踢出/删除用户
class UsersPage extends StatefulWidget {
  final AppController controller;

  const UsersPage({super.key, required this.controller});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

/// 共享对话框返回结果
class _ShareResult {
  final String folder; // 电脑端文件夹绝对路径
  final List<String> perms; // download / upload / delete

  const _ShareResult(this.folder, this.perms);
}

class _UsersPageState extends State<UsersPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.refreshUserList();
  }

  /// 显示操作结果提示（共享创建/踢出/删除等）
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

  /// 共享创建成功（_lastShareResult 非空）：公开共享显示二维码
  void _checkShareResult(AppController controller) {
    final share = controller.lastShareResult;
    if (share == null) return;
    controller.clearLastShareResult();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (share.isPublic) {
        _showQrDialog(share);
      }
    });
  }

  /// 共享二维码：`p2p:<服务器地址>|<配对码>|<共享码>`
  Future<void> _showQrDialog(ShareEntry share) async {
    final ctrl = widget.controller;
    final qrData =
        'p2p:${ctrl.lastServerUrl ?? ''}|${ctrl.lastPairCode ?? ''}|${share.token}';
    AppLog.i('share', '共享二维码内容: $qrData');
    await showDialog<void>(
      context: context,
      builder: (ctx) => _QrDialog(share: share, qrData: qrData),
    );
  }

  /// 打开共享文件夹选择对话框（目录选择 + 权限勾选，v5.4+ 仅二维码方式）
  Future<void> _openShareDialog() async {
    final result = await showDialog<_ShareResult>(
      context: context,
      builder: (_) => _ShareFolderDialog(
        controller: widget.controller,
      ),
    );
    if (result == null || !mounted) return;
    widget.controller.createShare(
      folder: result.folder,
      perms: result.perms,
    );
  }

  /// 生成管理员激活码（结果经 user:code-result 回传）
  /// v5.16+ 身份二态化：仅管理员码一种类型
  Future<void> _generateActCode() async {
    widget.controller.generateActCode();
  }

  /// 踢出/删除用户确认
  Future<void> _confirmUserAction(
      String title, String message, VoidCallback action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) action();
  }

  /// 共享文件夹列表项
  Widget _buildShareTile(ShareEntry s) {
    final ctrl = widget.controller;
    final bound = s.targetDeviceId != null || s.isPublic;
    // v5.4+ 去手机号：仅二维码共享，历史定向数据统一展示为定向共享
    final desc = s.isPublic ? '二维码（对方扫码加入）' : '定向共享';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.folder, color: Color(0xFFF59E0B), size: 28),
        title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.folder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(desc,
                      style: TextStyle(
                          fontSize: 12,
                          color: bound
                              ? const Color(0xFF0D9488)
                              : Colors.orange)),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (s.canDownload) '下载',
                if (s.canUpload) '上传',
                if (s.canDelete) '删除',
              ].join(' / '),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: (v) {
            switch (v) {
              case 'qr':
                _showQrDialog(s);
              case 'perms':
                _editPerms(s);
              case 'del':
                _confirmUserAction(
                  '删除共享？',
                  '删除后「${s.name}」将不再共享，所有已加入用户立即失去访问权',
                  () => ctrl.removeShare(s.token),
                );
            }
          },
          itemBuilder: (_) => [
            if (s.isPublic)
              const PopupMenuItem(value: 'qr', child: Text('查看二维码')),
            const PopupMenuItem(value: 'perms', child: Text('修改权限')),
            const PopupMenuItem(value: 'del', child: Text('删除共享')),
          ],
        ),
      ),
    );
  }

  /// 修改共享权限对话框（勾选下载/上传/删除）
  Future<void> _editPerms(ShareEntry s) async {
    final perms = Set<String>.of(s.perms);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('修改权限 - ${s.name}'),
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
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      widget.controller.updateSharePerms(s.token, perms.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('共享文件夹管理'),
        actions: [
          IconButton(
            tooltip: '生成激活码',
            icon: const Icon(Icons.vpn_key_outlined),
            onPressed: _generateActCode,
          ),
          IconButton(
            tooltip: '新增共享',
            icon: const Icon(Icons.create_new_folder),
            onPressed: _openShareDialog,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          _checkShareResult(controller);
          _showActionMessage(controller);
          if (!controller.isAdmin) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text('仅管理员可管理共享文件夹',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 16),
                  FilledButton.tonalIcon(
                    onPressed: () => controller.refreshUserList(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新获取权限'),
                  ),
                  const SizedBox(height: 8),
                  const Text('若仍无权限，请确认电脑端已更新为最新版本',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            );
          }
          final shares = controller.allShares;
          if (shares.isEmpty) {
            return const Center(
              child: Text('暂无共享文件夹\n点击右上角文件夹加号图标发起共享',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => controller.refreshUserList(),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              itemCount: shares.length,
              itemBuilder: (context, i) => _buildShareTile(shares[i]),
            ),
          );
        },
      ),
    );
  }
}

/// 共享二维码展示对话框：支持保存/分享二维码图片
class _QrDialog extends StatefulWidget {
  final ShareEntry share;
  final String qrData;

  const _QrDialog({required this.share, required this.qrData});

  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  final GlobalKey _qrKey = GlobalKey();
  bool _saving = false;

  String get _permsText {
    final list = <String>[
      if (widget.share.canDownload) '下载',
      if (widget.share.canUpload) '上传',
      if (widget.share.canDelete) '删除',
    ];
    return list.isEmpty ? '无操作权限' : '权限: ${list.join(' / ')}';
  }

  /// 把二维码区域截图保存为图片并调起系统分享（可保存到相册/发送给好友）
  Future<void> _saveQr() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary = _qrKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('二维码区域不可用');
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('二维码生成失败');
      final dir = await getTemporaryDirectory();
      final file =
          File('${dir.path}/share_qr_${widget.share.token}.png');
      await file.writeAsBytes(byteData.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'image/png')],
        text: '扫码加入共享文件夹「${widget.share.name}」（需安装本应用）',
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('共享二维码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            key: _qrKey,
            child: Container(
              padding: const EdgeInsets.all(10),
              color: Colors.white,
              child: QrImageView(
                data: widget.qrData,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text('共享文件夹: ${widget.share.name}',
              style: const TextStyle(fontSize: 13)),
          Text(_permsText,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          const Text('其他手机扫码后即可加入此共享目录',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _saveQr,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.save_alt, size: 18),
          label: Text(_saving ? '生成中…' : '保存 / 分享二维码'),
        ),
      ],
    );
  }
}

/// 共享文件夹选择对话框：浏览电脑端目录 + 权限勾选（v5.4+ 仅生成二维码）
class _ShareFolderDialog extends StatefulWidget {
  final AppController controller;

  const _ShareFolderDialog({
    required this.controller,
  });

  @override
  State<_ShareFolderDialog> createState() => _ShareFolderDialogState();
}

class _ShareFolderDialogState extends State<_ShareFolderDialog> {
  final Set<String> _perms = {'download', 'upload', 'delete'}; // 默认全选
  int _step = 0; // 0=选择文件夹 1=确认分享方式

  @override
  void initState() {
    super.initState();
    widget.controller.requestPickDirs();
  }

  /// 从本步骤返回上一步（选文件夹），保持目录不变
  void _backToFolder() {
    setState(() => _step = 0);
    widget.controller.requestPickDirs();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final segments = controller.pickPath.isEmpty
        ? <String>[]
        : controller.pickPath.split('/');
    return AlertDialog(
      title: Text(_step == 0 ? '选择要共享的文件夹' : '分享（生成二维码）'),
      content: SizedBox(
        width: double.maxFinite,
        height: 480,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: [
              if (_step == 1) ...[
                // 第一步已选中的文件夹提示
                Row(
                  children: [
                    const Icon(Icons.folder, size: 18, color: Color(0xFFF59E0B)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        controller.pickPath.isEmpty
                            ? '未选择文件夹'
                            : controller.pickPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // 二维码说明（v5.4+ 去手机号：仅二维码方式）
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
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
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  controller.pickPath.isEmpty
                      ? ''
                      : '共享文件夹: ${controller.pickPath}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ] else ...[
              // 路径面包屑
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    ActionChip(
                      label: const Text('远程电脑'),
                      onPressed: () => controller.navigatePick(-1),
                    ),
                    for (var i = 0; i < segments.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: ActionChip(
                          label: Text(segments[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          onPressed: () => controller.navigatePick(i),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // 文件夹列表（只显示目录）
              Expanded(
                child: controller.pickLoading
                    ? const Center(child: CircularProgressIndicator())
                    : controller.pickFiles.isEmpty
                        ? const Center(
                            child: Text('此目录为空',
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            itemCount: controller.pickFiles.length,
                            itemBuilder: (context, i) {
                              final d = controller.pickFiles[i];
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
                                onTap: () => controller.openPickDir(d),
                              );
                            },
                          ),
              ),
              const Divider(height: 1),
              // 权限勾选
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                              value: _perms.contains(perm),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(label),
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  _perms.add(perm);
                                } else {
                                  _perms.remove(perm);
                                }
                              }),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (_step == 1)
          TextButton(
            onPressed: _backToFolder,
            child: const Text('上一步'),
          ),
        if (_step == 0)
          FilledButton(
            onPressed: () {
              if (controller.pickPath.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请先选择要共享的文件夹')),
                );
                return;
              }
              setState(() => _step = 1);
            },
            child: const Text('下一步'),
          )
        else
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_ShareResult(
              controller.pickPath,
              _perms.toList(),
            )),
            icon: const Icon(Icons.qr_code_2, size: 18),
            label: const Text('生成共享二维码'),
          ),
      ],
    );
  }
}
