import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'app_controller.dart';
import 'app_log.dart';
import 'models.dart';

/// 在线视频播放页：边下边播（下载同时通过本地 HTTP 流式播放）
class VideoPlayerPage extends StatefulWidget {
  final AppController controller;
  final FileEntry entry;

  const VideoPlayerPage({
    super.key,
    required this.controller,
    required this.entry,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _player;
  Timer? _checkTimer;
  int _initFails = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.playVideo(widget.entry);
    });
    // 周期性检查播放地址就绪并初始化播放器（文件仍在下载，失败自动重试）
    _checkTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted) return;
      final url = widget.controller.playUrl;
      if (url == null) return; // 本地播放服务器尚未就绪
      if (_player != null) {
        if (widget.controller.playFinished) _checkTimer?.cancel();
        return;
      }
      _initPlayer(url);
    });
  }

  Future<void> _initPlayer(String url) async {
    final p = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await p.initialize();
      await p.setLooping(false);
      await p.play();
      if (!mounted) {
        await p.dispose();
        return;
      }
      AppLog.i('play', '播放器初始化成功: ${widget.entry.name}');
      setState(() => _player = p);
    } catch (e) {
      await p.dispose();
      // 数据不足导致初始化失败：继续重试（最多 60 次 ≈ 36 秒）
      _initFails++;
      if (_initFails == 1 || _initFails % 10 == 0) {
        AppLog.w('play', '播放器初始化失败(第$_initFails次): ${widget.entry.name} $e');
      }
      if (_initFails >= 60) {
        AppLog.e('play', '播放器初始化重试次数耗尽，放弃: ${widget.entry.name}');
        _checkTimer?.cancel();
      }
    }
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _player?.dispose();
    widget.controller.stopPlay();
    super.dispose();
  }

  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    if (p.value.isPlaying) {
      p.pause();
    } else {
      p.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.entry.name)),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final error = widget.controller.playError;
          final player = _player;

          // 播放失败（下载中断等）
          if (error != null && player == null) {
            return _StatusView(
              icon: Icons.error_outline,
              text: error,
              action: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回'),
              ),
            );
          }

          // 播放器已就绪
          if (player != null) {
            return _buildPlayer(player, theme);
          }

          // 等待/下载中
          return _buildLoading(theme);
        },
      ),
    );
  }

  /// 下载中：显示进度
  Widget _buildLoading(ThemeData theme) {
    final total = widget.controller.activeDownloadSize;
    final done = widget.controller.activeDownloadBytes;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    return _StatusView(
      icon: Icons.movie_outlined,
      text: widget.controller.playUrl == null
          ? '正在连接电脑获取视频...'
          : '正在启动播放器...',
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 120,
              child: LinearProgressIndicator(value: progress),
            ),
            const SizedBox(height: 8),
            Text(
              total > 0
                  ? '已加载 ${(done / 1048576).toStringAsFixed(1)} / '
                      '${(total / 1048576).toStringAsFixed(1)} MB'
                      '（${(progress * 100).toStringAsFixed(0)}%）'
                  : '等待文件信息...',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            const Text('边下边播，无需等待下载完成',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  /// 播放器 + 控制条 + 下载状态
  Widget _buildPlayer(VideoPlayerController p, ThemeData theme) {
    return Column(
      children: [
        // 视频画面
        AspectRatio(
          aspectRatio:
              p.value.aspectRatio > 0 ? p.value.aspectRatio : 16 / 9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(
                onTap: _togglePlay,
                child: VideoPlayer(p),
              ),
              // 暂停时显示播放图标
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: p,
                builder: (context, value, _) {
                  if (value.isPlaying) return const SizedBox.shrink();
                  return GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.play_arrow,
                          size: 48, color: Colors.white),
                    ),
                  );
                },
              ),
            ],
          ),
        ),

        // 播放控制条
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: p,
          builder: (context, value, _) {
            final pos = value.position;
            final dur = value.duration;
            String fmt(Duration d) {
              final h = d.inHours > 0 ? '${d.inHours}:' : '';
              final m = (d.inMinutes % 60).toString().padLeft(2, '0');
              final s = (d.inSeconds % 60).toString().padLeft(2, '0');
              return '$h$m:$s';
            }

            return Row(
              children: [
                IconButton(
                  onPressed: _togglePlay,
                  icon: Icon(value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow),
                ),
                Expanded(
                  child: Slider(
                    value: (dur.inMilliseconds > 0
                            ? pos.inMilliseconds
                            : 0)
                        .clamp(0, dur.inMilliseconds > 0 ? dur.inMilliseconds : 1)
                        .toDouble(),
                    max: dur.inMilliseconds > 0
                        ? dur.inMilliseconds.toDouble()
                        : 1,
                    onChanged: (v) {
                      p.seekTo(Duration(milliseconds: v.round()));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text('${fmt(pos)} / ${fmt(dur)}',
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            );
          },
        ),

        // 下载状态提示
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final c = widget.controller;
              final total = c.activeDownloadSize;
              final done = c.activeDownloadBytes;
              if (c.playFinished) {
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle,
                          size: 18, color: Color(0xFF2E7D32)),
                      SizedBox(width: 8),
                      Text('视频已全部下载完成',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFF2E7D32))),
                    ],
                  ),
                );
              }
              if (c.activeDownloadName != null && total > 0) {
                final progress = (done / total).clamp(0.0, 1.0);
                return Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('正在后台下载视频...',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFF1565C0))),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: progress),
                    ],
                  ),
                );
              }
              return const SizedBox(height: 12);
            },
          ),
        ),
      ],
    );
  }
}

class _StatusView extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? child;
  final Widget? action;

  const _StatusView({required this.icon, required this.text, this.child, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.grey),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
            ?child,
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
