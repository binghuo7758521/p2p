import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'protocol.dart';

/// 下载进度横幅（v5.24+ 公共组件）：主页与共享浏览页共用。
/// 显示当前下载的文件名、连接方式、实时速度、已下载/总大小、进度条与停止按钮。
/// 由调用方在 `activeDownloadName != null` 时渲染，下载完成/失败/停止后自动消失。
class DownloadBanner extends StatefulWidget {
  final AppController controller;

  const DownloadBanner({super.key, required this.controller});

  @override
  State<DownloadBanner> createState() => _DownloadBannerState();
}

class _DownloadBannerState extends State<DownloadBanner> {
  Timer? _speedTimer;
  int _lastBytes = 0;
  DateTime _lastTick = DateTime.now();
  /// 实时下载速度（字节/秒，500ms 滑动差分）
  double _speed = 0;

  @override
  void initState() {
    super.initState();
    _lastBytes = widget.controller.activeDownloadBytes;
    _lastTick = DateTime.now();
    // 500ms 差分计算速度并刷新（进度状态本身已节流更新，不增加主线程负担）
    _speedTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final bytes = widget.controller.activeDownloadBytes;
      final dt = now.difference(_lastTick).inMilliseconds;
      if (dt > 0 && bytes >= _lastBytes) {
        _speed = (bytes - _lastBytes) * 1000 / dt;
      }
      _lastBytes = bytes;
      _lastTick = now;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  String _speedLabel(double speed) {
    if (speed <= 0) return '';
    if (speed >= 1048576) {
      return '${(speed / 1048576).toStringAsFixed(1)} MB/s';
    }
    return '${(speed / 1024).toStringAsFixed(0)} KB/s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final total = controller.activeDownloadSize;
    final done = controller.activeDownloadBytes;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    final speedLabel = _speedLabel(_speed);
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
                if (controller.connectionType.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ConnChip(label: controller.connTypeLabel),
                ],
                const SizedBox(width: 8),
                Text(
                  speedLabel.isEmpty
                      ? '${formatSize(done)} / ${formatSize(total)}'
                      : '${formatSize(done)} / ${formatSize(total)} · $speedLabel',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(width: 4),
                // 手动停止下载：发送中止消息 + 清理 .part（防误触样式与删除一致）
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Colors.redAccent, size: 20),
                  tooltip: '停止下载',
                  onPressed: () => controller.stopDownload(),
                ),
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

/// 上传进度横幅（v5.25+ 公共组件）：主页与共享浏览页共用，与 DownloadBanner 对称。
/// 显示当前上传的文件名、连接方式、实时速度、已上传/总大小、进度条与停止按钮。
/// 由调用方在 `activeUploadName != null` 时渲染，批次结束/停止后自动消失。
class UploadBanner extends StatefulWidget {
  final AppController controller;

  const UploadBanner({super.key, required this.controller});

  @override
  State<UploadBanner> createState() => _UploadBannerState();
}

class _UploadBannerState extends State<UploadBanner> {
  Timer? _speedTimer;
  int _lastBytes = 0;
  DateTime _lastTick = DateTime.now();
  /// 实时上传速度（字节/秒，500ms 滑动差分）
  double _speed = 0;

  @override
  void initState() {
    super.initState();
    _lastBytes = widget.controller.activeUploadBytes;
    _lastTick = DateTime.now();
    // 500ms 差分计算速度并刷新（进度状态本身已节流更新，不增加主线程负担）
    _speedTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      final bytes = widget.controller.activeUploadBytes;
      final dt = now.difference(_lastTick).inMilliseconds;
      if (dt > 0 && bytes >= _lastBytes) {
        _speed = (bytes - _lastBytes) * 1000 / dt;
      }
      _lastBytes = bytes;
      _lastTick = now;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    super.dispose();
  }

  String _speedLabel(double speed) {
    if (speed <= 0) return '';
    if (speed >= 1048576) {
      return '${(speed / 1048576).toStringAsFixed(1)} MB/s';
    }
    return '${(speed / 1024).toStringAsFixed(0)} KB/s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final total = controller.activeUploadSize;
    final done = controller.activeUploadBytes;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    final speedLabel = _speedLabel(_speed);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.upload, size: 18, color: Colors.teal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('正在上传: ${controller.activeUploadName}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                if (controller.connectionType.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ConnChip(label: controller.connTypeLabel),
                ],
                const SizedBox(width: 8),
                Text(
                  speedLabel.isEmpty
                      ? '${formatSize(done)} / ${formatSize(total)}'
                      : '${formatSize(done)} / ${formatSize(total)} · $speedLabel',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(width: 4),
                // 手动停止上传：本地中止发送（电脑端接收超时兜底收尾）
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: Colors.redAccent, size: 20),
                  tooltip: '停止上传',
                  onPressed: () => controller.stopUpload(),
                ),
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

/// 连接方式徽标：绿=点对点直连 橙=服务器中转（v5.24+ 公共组件，主页/共享页复用）
class ConnChip extends StatelessWidget {
  final String label;

  const ConnChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final direct = label.contains('直连');
    final relay = label.contains('中转');
    // 探测未完成/已连接（方式未知）：灰色中性展示，不误导为已确认的方式
    final color = direct
        ? Colors.green.shade700
        : (relay ? Colors.orange.shade800 : Colors.grey.shade600);
    final bg =
        direct ? Colors.green : (relay ? Colors.orange : Colors.grey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(direct ? Icons.link : Icons.hub, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
