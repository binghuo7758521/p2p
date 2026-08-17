import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'host_controller.dart';

/// 电脑端手机端管理页（v5.9+）：
/// 激活码发放/撤销 + 用户管理（备注名称/重置密码/更换管理员/踢出/删除）
class UsersManagePage extends StatefulWidget {
  final HostController controller;

  const UsersManagePage({super.key, required this.controller});

  @override
  State<UsersManagePage> createState() => _UsersManagePageState();
}

class _UsersManagePageState extends State<UsersManagePage> {
  /// 踢出/删除/撤销确认；返回是否确认（供后续流程使用）
  Future<bool?> _confirmUserAction(
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
    if (ok == true && mounted) action();
    return ok;
  }

  /// 用户状态描述（在线/离线 + 角色 + 加入时间）
  String _userDesc(HostUser u) {
    final parts = <String>[
      u.online ? '在线' : '离线',
      if (u.isAdmin) '管理员',
      if (u.shareOnly) '共享访客',
      if (u.pendingReset) '待新密码',
    ];
    final time = '${u.joinedAt.month}/${u.joinedAt.day} '
        '${u.joinedAt.hour.toString().padLeft(2, '0')}:'
        '${u.joinedAt.minute.toString().padLeft(2, '0')} 加入';
    return '${parts.join(' · ')} · $time';
  }

  /// 生成管理员激活码 → 展示生成的码（可复制）
  /// v6.14+ 身份二态化：仅管理员码一种类型
  Future<void> _showGenCodeDialog() async {
    final code = widget.controller.generateActCode();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('管理员激活码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请将激活码发送给手机端用户：\n'
                '24 小时内有效，使用一次后作废\n'
                '手机端激活后自动成为本电脑管理员'),
            const SizedBox(height: 12),
            // 激活码二维码（内容 p2p-act:server|码，手机端扫码页可直接识别）
            QrImageView(
              data: 'p2p-act:${widget.controller.serverUrl}|$code',
              size: 180,
              backgroundColor: Colors.white,
              padding: const EdgeInsets.all(8),
            ),
            const SizedBox(height: 12),
            const Text('或让对方扫码激活：',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            SelectableText(
              code,
              style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制激活码'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('已复制'), duration: Duration(seconds: 1)));
              },
            ),
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

  /// 撤销激活码（未使用的码立即失效）
  void _confirmRevoke(ActCodeEntry c) {
    _confirmUserAction(
      '撤销激活码？',
      '撤销后该码立即失效，手机端无法再使用它激活。',
      () => widget.controller.revokeActCode(c.code),
    );
  }

  /// 编辑用户备注名称
  Future<void> _editRemark(HostUser u) async {
    final ctrl = TextEditingController(text: u.remark);
    final remark = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('备注名称 - ${u.displayName}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            hintText: '如：张老板 / 门店收银台',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (remark != null && mounted) {
      widget.controller.setUserRemark(u.deviceId, remark);
    }
  }

  /// 重置连接密码：确认后展示一次性新密码
  Future<void> _resetPassword(HostUser u) async {
    final ok = await _confirmUserAction(
      '重置连接密码？',
      '将为「${u.displayName}」生成新的 6 位连接密码，\n'
      '该客户需用新密码重新连接（在线时立即收到新密码）。',
      () {},
    );
    if (ok != true || !mounted) return;
    final pwd = widget.controller.resetUserPassword(u.deviceId);
    if (pwd == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新连接密码已生成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请将新密码告知客户（仅显示这一次）：'),
            const SizedBox(height: 12),
            SelectableText(
              pwd,
              style: const TextStyle(
                  fontSize: 28, letterSpacing: 6, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制密码'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: pwd));
                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                    content: Text('已复制'), duration: Duration(seconds: 1)));
              },
            ),
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

  /// 更换管理员（移交）
  Future<void> _transferAdmin(HostUser u) async {
    await _confirmUserAction(
      '更换管理员？',
      '将管理员移交给「${u.displayName}」？\n'
      '原管理员自动降级，失去管理权限。',
      () => widget.controller.transferAdmin(u.deviceId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('手机端管理'),
        actions: [
          IconButton(
            tooltip: '生成激活码',
            icon: const Icon(Icons.card_giftcard_outlined),
            onPressed: _showGenCodeDialog,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final users = controller.users.values.toList();
          final codes = controller.actCodeList
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          return Column(
            children: [
              // ── 激活码区（生成后展示，可撤销） ──
              if (codes.isNotEmpty)
                SizedBox(
                  height: 52,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: codes.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final c = codes[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: c.isAdmin
                              ? const Color(0xFF38BDF8).withValues(alpha: 0.12)
                              : Theme.of(context)
                                  .colorScheme
                                  .secondaryContainer
                                  .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: c.isAdmin
                                ? const Color(0xFF38BDF8)
                                : Theme.of(context)
                                    .colorScheme
                                    .outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              c.isAdmin ? Icons.shield : Icons.smartphone,
                              size: 14,
                              color: c.isAdmin
                                  ? const Color(0xFF38BDF8)
                                  : Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              c.code,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              c.used ? '已用' : '未用',
                              style: TextStyle(
                                fontSize: 11,
                                color: c.used ? Colors.grey : Colors.green,
                              ),
                            ),
                            IconButton(
                              tooltip: '撤销',
                              icon: const Icon(Icons.close, size: 16),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _confirmRevoke(c),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              // ── 用户列表 ──
              Expanded(
                child: users.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.smartphone,
                                size: 64, color: Colors.grey),
                            SizedBox(height: 12),
                            Text('暂无手机端连接记录',
                                style: TextStyle(color: Colors.grey)),
                            SizedBox(height: 4),
                            Text('手机端输入激活码连接后，将显示在这里',
                                style:
                                    TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: users.length,
                        itemBuilder: (_, i) {
                          final u = users[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: u.isAdmin
                                    ? const Color(0xFF38BDF8)
                                    : (u.online
                                        ? Colors.green
                                        : Colors.grey),
                                child: Icon(
                                  u.isAdmin
                                      ? Icons.shield
                                      : u.shareOnly
                                          ? Icons.folder_shared
                                          : Icons.smartphone,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                              title: Text(
                                u.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_userDesc(u)),
                                  if (u.remark.isNotEmpty)
                                    Text('备注 ${u.remark}'),
                                  Text('设备 ${u.deviceId}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ],
                              ),
                              trailing: u.isAdmin
                                  ? null // 管理员不可操作（移交从普通用户侧发起）
                                  : PopupMenuButton<String>(
                                      tooltip: '操作',
                                      onSelected: (v) {
                                        switch (v) {
                                          case 'kick':
                                            _confirmUserAction(
                                              '踢出用户？',
                                              '将断开「${u.displayName}」的当前连接，\n'
                                                  '对方可重新激活连接。',
                                              () => controller
                                                  .kickUser(u.deviceId),
                                            );
                                          case 'del':
                                            _confirmUserAction(
                                              '删除用户？',
                                              '将断开「${u.displayName}」并移除其连接记录与共享权限，\n'
                                                  '对方需新的激活码才能再次连接。',
                                              () => controller
                                                  .removeUser(u.deviceId),
                                            );
                                          case 'remark':
                                            _editRemark(u);
                                          case 'pwd':
                                            _resetPassword(u);
                                          case 'admin':
                                            _transferAdmin(u);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        if (u.online)
                                          const PopupMenuItem(
                                              value: 'kick',
                                              child: Text('踢出')),
                                        const PopupMenuItem(
                                            value: 'remark',
                                            child: Text('备注名称')),
                                        const PopupMenuItem(
                                            value: 'pwd',
                                            child: Text('重置密码')),
                                        if (!u.shareOnly)
                                          const PopupMenuItem(
                                              value: 'admin',
                                              child: Text('更换管理员')),
                                        const PopupMenuItem(
                                            value: 'del',
                                            child: Text('删除')),
                                      ],
                                    ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
