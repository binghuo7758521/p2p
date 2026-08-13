import 'package:flutter/material.dart';

import 'host_controller.dart';

/// 电脑端手机端管理页：查看有连接权限的手机端（在线/离线），踢出或删除
class UsersManagePage extends StatefulWidget {
  final HostController controller;

  const UsersManagePage({super.key, required this.controller});

  @override
  State<UsersManagePage> createState() => _UsersManagePageState();
}

class _UsersManagePageState extends State<UsersManagePage> {
  /// 踢出/删除确认
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
    if (ok == true && mounted) action();
  }

  /// 用户状态描述（在线/离线 + 角色 + 加入时间）
  String _userDesc(HostUser u) {
    final parts = <String>[
      u.online ? '在线' : '离线',
      if (u.isAdmin) '管理员',
      if (u.shareOnly) '共享访客',
    ];
    final time = '${u.joinedAt.month}/${u.joinedAt.day} '
        '${u.joinedAt.hour.toString().padLeft(2, '0')}:'
        '${u.joinedAt.minute.toString().padLeft(2, '0')} 加入';
    return '${parts.join(' · ')} · $time';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('手机端管理')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final users = controller.users.values.toList();
          if (users.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.smartphone, size: 64, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('暂无手机端连接记录',
                      style: TextStyle(color: Colors.grey)),
                  SizedBox(height: 4),
                  Text('手机端扫码或输入配对码连接后，将显示在这里',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: users.length,
            itemBuilder: (_, i) {
              final u = users[i];
              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: u.isAdmin
                        ? const Color(0xFF38BDF8)
                        : (u.online ? Colors.green : Colors.grey),
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
                    u.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_userDesc(u)),
                      if (u.phone.isNotEmpty) Text('手机号 ${u.phone}'),
                      Text('设备 ${u.deviceId}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                  trailing: u.isAdmin
                      ? null // 管理员不能操作
                      : PopupMenuButton<String>(
                          tooltip: '操作',
                          onSelected: (v) {
                            switch (v) {
                              case 'kick':
                                _confirmUserAction(
                                  '踢出用户？',
                                  '将断开「${u.name}」的当前连接，\n'
                                      '对方可凭配对码重新加入。',
                                  () => controller.kickUser(u.deviceId),
                                );
                              case 'del':
                                _confirmUserAction(
                                  '删除用户？',
                                  '将断开「${u.name}」并移除其连接记录与共享权限，\n'
                                      '对方重新扫码配对后才能再次连接。',
                                  () => controller.removeUser(u.deviceId),
                                );
                            }
                          },
                          itemBuilder: (_) => [
                            if (u.online)
                              const PopupMenuItem(
                                  value: 'kick', child: Text('踢出')),
                            const PopupMenuItem(
                                value: 'del', child: Text('删除')),
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
}
