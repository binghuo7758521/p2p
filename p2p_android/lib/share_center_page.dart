import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_log.dart';
import 'models.dart';
import 'share_browse_page.dart';

/// 共享中心（v4.8+）：“共享给我的”列表
/// 数据源：服务器共享注册表（电脑端同步），激活后免配对码直接连接
class ShareCenterPage extends StatefulWidget {
  final AppController controller;

  const ShareCenterPage({super.key, required this.controller});

  @override
  State<ShareCenterPage> createState() => _ShareCenterPageState();
}

class _ShareCenterPageState extends State<ShareCenterPage> {
  List<ServerShare> _shares = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final list = await widget.controller.fetchMyShares();
    if (!mounted) return;
    setState(() {
      _shares = list;
      _loading = false;
      if (list.isEmpty) {
        _error = '暂无共享给你的文件夹\n请让电脑端管理员在“共享文件夹管理”中生成共享二维码，用本应用扫码加入';
      }
    });
  }

  /// 连接共享并进入浏览页
  Future<void> _openShare(ServerShare share) async {
    if (!share.online) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('该共享的电脑不在线，请稍后再试'),
      ));
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在连接电脑…'),
              ],
            ),
          ),
        ),
      ),
    );
    final ok = await widget.controller.connectByShare(share);
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭连接中对话框
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            '连接失败：${widget.controller.errorMessage ?? '电脑端暂不可达，请稍后再试'}'),
      ));
      return;
    }
    AppLog.i('share', '免配对码连接成功，进入共享浏览: ${share.name}');
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ShareBrowsePage(controller: widget.controller),
    ));
    // 返回后断开连接，避免占用共享资源
    await widget.controller.disconnect();
  }

  String _permsText(ServerShare share) {
    final parts = <String>[
      if (share.canDownload) '下载',
      if (share.canUpload) '上传',
      if (share.canDelete) '删除',
    ];
    return parts.isEmpty ? '只读' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('共享给我的')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _shares.isEmpty
                ? _buildEmpty()
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _shares.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final s = _shares[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: s.online
                              ? Colors.green.withValues(alpha: 0.15)
                              : Colors.grey.withValues(alpha: 0.15),
                          child: Icon(
                            s.online
                                ? Icons.computer
                                : Icons.computer_outlined,
                            color: s.online ? Colors.green : Colors.grey,
                          ),
                        ),
                        title: Text(s.name,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w500)),
                        subtitle: Text(
                          '${s.hostName}${s.online ? '' : ' · 离线'}',
                          style: TextStyle(
                            fontSize: 12,
                            color: s.online ? Colors.grey : Colors.grey,
                          ),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _permsText(s),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  s.online
                                      ? Icons.circle
                                      : Icons.circle_outlined,
                                  size: 8,
                                  color:
                                      s.online ? Colors.green : Colors.grey,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  s.online ? '可连接' : '离线',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: s.online
                                          ? Colors.green
                                          : Colors.grey),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _openShare(s),
                      );
                    },
                  ),
      ),
    );
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(Icons.inbox_outlined,
            size: 72, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Center(
          child: Text(
            _error ?? '暂无共享',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, height: 1.6),
          ),
        ),
        const SizedBox(height: 40),
        Center(
          child: TextButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新'),
          ),
        ),
      ],
    );
  }
}
