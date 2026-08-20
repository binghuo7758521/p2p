import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'app_controller.dart';
import 'app_log.dart';
import 'dlnacast_service.dart';
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

  // v5.33+ 投影状态
  final DlnaCastService _castService = DlnaCastService();
  CastDevice? _castDevice; // 投影目标设备
  bool _casting = false; // 是否投影中
  bool _castPlaying = false; // 电视端播放状态
  Duration _castPos = Duration.zero; // 电视端播放位置（轮询同步）
  Duration _castDur = Duration.zero; // 视频总时长（轮询同步）
  Timer? _castTimer; // 位置轮询定时器

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

  /// 切换投影：未投影→弹设备列表；投影中→断开
  Future<void> _toggleCast() async {
    if (_casting) {
      await _stopCast();
      return;
    }
    final device = await showModalBottomSheet<CastDevice>(
      context: context,
      showDragHandle: true,
      builder: (_) => _CastSheet(service: _castService),
    );
    if (device == null || !mounted) return;
    await _startCast(device);
  }

  /// 开始投影：设置播放源 → 播放 → 本地暂停 → 进入遥控器模式
  Future<void> _startCast(CastDevice device) async {
    final url = await widget.controller.buildCastUrl();
    if (url == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('投影失败：视频数据尚未就绪，请稍候再试'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    // 格式兼容提示：电视解码能力有限，小众格式先确认
    final ext = widget.entry.name.split('.').last.toLowerCase();
    const risky = {
      'mkv', 'avi', 'wmv', 'flv', 'ts', '3gp', '3gpp', 'mpg', 'mpeg',
    };
    if (!mounted) return;
    if (risky.contains(ext)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('格式兼容提示'),
          content: const Text('该视频格式电视可能无法播放，\n仍要继续投影吗？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('继续投影')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final ok = await _castService.setAvTransportUri(device, url);
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('投影失败：${device.name} 无响应'),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    await _castService.play(device);
    _player?.pause(); // 本地暂停（省流量，手机变遥控器）
    setState(() {
      _castDevice = device;
      _casting = true;
      _castPlaying = true;
      _castPos = Duration.zero;
      _castDur = Duration.zero;
    });
    AppLog.i('cast', '已投影到: ${device.name} ($url)');
    _startCastPolling();
  }

  /// 周期同步电视播放位置与状态（遥控器进度条）
  void _startCastPolling() {
    _castTimer?.cancel();
    _castTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final d = _castDevice;
      if (d == null) return;
      final (pos, dur, playing) = await _castService.getPositionInfo(d);
      if (!mounted || _castDevice != d) return;
      setState(() {
        if (pos != null) _castPos = pos;
        if (dur != null && dur.inSeconds > 0) _castDur = dur;
        _castPlaying = playing;
      });
    });
  }

  /// 断开投影：电视停止 → 恢复本地播放
  Future<void> _stopCast() async {
    final d = _castDevice;
    _castTimer?.cancel();
    setState(() {
      _casting = false;
      _castDevice = null;
      _castPlaying = false;
    });
    if (d != null) await _castService.stop(d);
    _player?.play(); // 恢复本地播放
    AppLog.i('cast', '已断开投影: ${d?.name}');
  }

  /// 遥控器：播放/暂停切换（电视端）
  Future<void> _castTogglePlay() async {
    final d = _castDevice;
    if (d == null) return;
    if (_castPlaying) {
      final ok = await _castService.pause(d);
      if (ok && mounted) setState(() => _castPlaying = false);
    } else {
      final ok = await _castService.play(d);
      if (ok && mounted) setState(() => _castPlaying = true);
    }
  }

  /// 遥控器：拖动进度条松手后跳转到电视播放位置
  Future<void> _castSeekEnd(double ms) async {
    final d = _castDevice;
    if (d == null) return;
    await _castService.seek(d, Duration(milliseconds: ms.round()));
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _castTimer?.cancel();
    final d = _castDevice;
    if (_casting && d != null) {
      _castService.stop(d); // 退出页面前通知电视停止（尽力而为）
    }
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
      appBar: AppBar(
        title: Text(widget.entry.name),
        actions: [
          // v5.33+ 投影入口：播放器就绪后可投；投影中显示连接状态
          if (_player != null || _casting)
            IconButton(
              tooltip: _casting ? '停止投影' : '投影到电视',
              icon: Icon(
                _casting ? Icons.cast_connected : Icons.cast,
                color: _casting ? Colors.blueAccent : null,
              ),
              onPressed: _toggleCast,
            ),
        ],
      ),
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

        // 投影状态条（v5.33+）
        if (_casting && _castDevice != null) _buildCastBanner(theme),
        // 播放控制条：投影中为遥控器模式，否则本地控制
        if (_casting && _castDevice != null)
          _buildCastControls(theme)
        else
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

  /// 投影状态条：设备名 + 断开按钮（v5.33+）
  Widget _buildCastBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE3F2FD),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.cast_connected, size: 18, color: Color(0xFF1565C0)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '正在投影到：${_castDevice!.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF1565C0)),
            ),
          ),
          TextButton(
            onPressed: _stopCast,
            child: const Text('断开', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 遥控器模式控制条（投影中）：播放/暂停 + 进度拖动 + 时间（v5.33+）
  Widget _buildCastControls(ThemeData theme) {
    String fmt(Duration d) {
      final h = d.inHours > 0 ? '${d.inHours}:' : '';
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      final s = (d.inSeconds % 60).toString().padLeft(2, '0');
      return '$h$m:$s';
    }

    final durMs = _castDur.inMilliseconds;
    return Row(
      children: [
        IconButton(
          onPressed: _castTogglePlay,
          icon: Icon(_castPlaying ? Icons.pause : Icons.play_arrow),
        ),
        Expanded(
          child: Slider(
            value: _castPos.inMilliseconds
                .clamp(0, durMs > 0 ? durMs : 1)
                .toDouble(),
            max: durMs > 0 ? durMs.toDouble() : 1,
            // 拖动中本地预览位置，松手后才发送 Seek 到电视
            onChanged: (v) =>
                setState(() => _castPos = Duration(milliseconds: v.round())),
            onChangeEnd: _castSeekEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text('${fmt(_castPos)} / ${fmt(_castDur)}',
              style: const TextStyle(fontSize: 12)),
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

/// 投影设备选择底部弹窗（v5.33+）：搜索并列出局域网 DLNA 接收端
class _CastSheet extends StatefulWidget {
  final DlnaCastService service;

  const _CastSheet({required this.service});

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  List<CastDevice> _devices = [];
  bool _searching = true;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _devices = [];
    });
    final list = await widget.service.discover();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 360,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('投影到设备',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            Expanded(
              child: _searching
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('正在搜索局域网设备…',
                              style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    )
                  : _devices.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '未发现可投影的设备\n请确认电视/盒子已开启投屏接收（DLNA），\n且与本手机连接同一 Wi-Fi',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.grey.shade600, height: 1.6),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _devices.length,
                          itemBuilder: (context, i) {
                            final d = _devices[i];
                            return ListTile(
                              leading: const Icon(Icons.tv,
                                  color: Color(0xFF38BDF8)),
                              title: Text(d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(d.location.host,
                                  style: const TextStyle(fontSize: 12)),
                              onTap: () => Navigator.of(context).pop(d),
                            );
                          },
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: OutlinedButton.icon(
                onPressed: _searching ? null : _search,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新搜索'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
