import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'app_log.dart';

/// 视频扩展名集合（用于识别可在线播放的视频文件）
const kVideoExts = {
  'mp4', 'mkv', 'webm', 'avi', 'mov', '3gp', '3gpp',
  'flv', 'wmv', 'ts', 'm4v', 'mpg', 'mpeg',
};

/// 判断文件名是否为视频
bool isVideoFile(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return kVideoExts.contains(name.substring(dot + 1).toLowerCase());
}

/// 根据扩展名返回视频 MIME 类型
String mimeForVideo(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  switch (ext) {
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mkv':
      return 'video/x-matroska';
    case 'webm':
      return 'video/webm';
    case 'avi':
      return 'video/x-msvideo';
    case 'mov':
      return 'video/quicktime';
    case '3gp':
    case '3gpp':
      return 'video/3gpp';
    case 'flv':
      return 'video/x-flv';
    case 'wmv':
      return 'video/x-ms-wmv';
    case 'ts':
      return 'video/mp2t';
    case 'mpg':
    case 'mpeg':
      return 'video/mpeg';
    default:
      return 'application/octet-stream';
  }
}

/// 本地视频流媒体服务器：
/// 把正在下载中的临时文件以 HTTP 流式方式提供（支持 Range 与边下边播），
/// 供 video_player 在线播放；v5.33+ 同时供 DLNA 投屏设备拉流。
class VideoPlayServer {
  HttpServer? _server;

  /// 投屏防盗播令牌：非本机（loopback）访问必须携带（v5.33+）
  String castToken = '';

  /// 当前服务器端口（未启动时为 null）
  int? get port => _server?.port;

  /// 启动本地 HTTP 服务器（绑定 0.0.0.0 局域网可达，供 DLNA 投屏）。
  /// [file] 为正在被写入的临时视频文件；
  /// [isFinished] 返回下载是否已完成（到达 EOF 且完成后流才结束）；
  /// [expectedSize] 视频总大小（电脑端下发的 fileSize），
  /// 用于填充 Content-Length/Content-Range，保证电视端边下边播（v5.34+）。
  /// 返回服务器端口。
  Future<int> start(
    File file, {
    required bool Function() isFinished,
    required String mime,
    int expectedSize = 0,
  }) async {
    castToken =
        List.generate(12, (_) => Random().nextInt(16).toRadixString(16))
            .join();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen((req) {
      _handle(req, file, isFinished, mime, expectedSize).catchError((e) {
        AppLog.w('play', '播放请求处理异常: ${req.uri.path} $e');
        try {
          req.response.statusCode = 500;
          req.response.close();
        } catch (_) {}
      });
    });
    AppLog.i('play', '本地播放服务器已绑定: 0.0.0.0:${_server!.port} (文件=${file.path})');
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    AppLog.i('play', '本地播放服务器已停止');
  }

  Future<void> _handle(
    HttpRequest req,
    File file,
    bool Function() isFinished,
    String mime,
    int expectedSize,
  ) async {
    final res = req.response;
    // v5.33+ 防盗播：本机（loopback）播放放行；局域网投屏必须携带正确 token
    final remote = req.connectionInfo?.remoteAddress;
    final fromLoopback =
        remote != null && (remote.isLoopback || remote.isLinkLocal);
    if (!fromLoopback && req.uri.queryParameters['token'] != castToken) {
      AppLog.w('play', '投屏请求 token 校验失败: ${remote?.address}');
      res.statusCode = 403;
      await res.close();
      return;
    }
    if (req.uri.path != '/play') {
      AppLog.w('play', '未知请求路径: ${req.uri.path}');
      res.statusCode = 404;
      await res.close();
      return;
    }

    // 解析 Range 头（ExoPlayer 等播放器会请求 bytes=start-end）
    final range = req.headers.value(HttpHeaders.rangeHeader);
    // v5.34+：总大小优先用电脑端下发的 fileSize（下载中文件在增长，
    // 用当前大小会导致电视无法定位/边下边播失效）
    final total = expectedSize > 0 ? expectedSize : await file.length();
    var start = 0;
    var end = -1; // 仅在带 Range 时有效（包含的最后一个字节）
    var hasRange = false;
    if (range != null && range.startsWith('bytes=')) {
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (m != null) {
        hasRange = true;
        start = int.tryParse(m.group(1) ?? '') ?? 0;
        final endPart = int.tryParse(m.group(2) ?? '');
        end = endPart ?? (total > 0 ? total - 1 : start);
        if (end < start) end = start;
        if (total > 0 && end > total - 1) end = total - 1; // 超界保护
      }
    }
    AppLog.i('play',
        '播放请求: method=${req.method} range=${range ?? '无'} => ${hasRange ? '206' : '200'} start=$start end=$end total=$total (文件当前大小=${await file.length()})');

    // 请求范围超出资源大小：416（如电视探测超界 Range）
    if (total > 0 && start >= total) {
      res.statusCode = 416;
      await res.close();
      return;
    }

    res.statusCode = hasRange ? 206 : 200;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    // v5.36+：Content-Length 仅对局域网投屏（电视/DLNA 需知晓总大小才边下边播）设置；
    // 本机播放（ExoPlayer）不设：播放器按需部分读取会中途断开连接，
    // 下载完成瞬间 stat/read 短暂不一致时发送量不足 CL，会判定失败并无限重试
    // （v5.35 崩溃根因：重试风暴 + 挂起连接耗尽资源）
    if (hasRange) {
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      if (expectedSize > 0 && !fromLoopback) {
        res.headers.set(
            HttpHeaders.contentLengthHeader, (end - start + 1).toString());
      }
    } else if (expectedSize > 0 && !fromLoopback) {
      res.headers.set(HttpHeaders.contentLengthHeader, total.toString());
    }
    res.headers.set(HttpHeaders.contentTypeHeader, mime);
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    // DLNA 拉流兼容头（部分电视/盒子要求，提升投屏成功率）
    res.headers.set('transferMode.dlna.org', 'Streaming');
    res.headers.set('contentFeatures.dlna.org',
        'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000');

    // HEAD 探测请求（部分电视先探测资源）：只返回响应头
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }

    // 流式读取：文件未写完时等待写入（边下边播），完成后读到 EOF 结束；
    // 带 Range 时精确发送到 end 上界，与 Content-Length 一致
    var sent = 0;
    await res.addStream(_readRange(file, start, end, isFinished)
        .map((d) { sent += d.length; return d; }));
    await res.close();
    AppLog.i('play', '播放响应完成: 发送$sent字节 (请求start=$start)');
  }

  Stream<List<int>> _readRange(
    File file,
    int start,
    int end, // 包含的最后一个字节；-1 = 无上界（读到 EOF/下载完成）
    bool Function() isFinished,
  ) async* {
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      var pos = start;
      // v5.36+ 超时兜底：下载中断且未标记完成（极端异常）时，
      // 文件 60s 无增长则断开，避免挂起连接/文件句柄泄漏
      var lastLen = start;
      var lastGrowMs = DateTime.now().millisecondsSinceEpoch;
      while (true) {
        final len = await file.length();
        if (pos >= len) {
          if (isFinished()) break; // 下载完成且已读到末尾
          final now = DateTime.now().millisecondsSinceEpoch;
          if (len > lastLen) {
            lastLen = len;
            lastGrowMs = now;
          }
          if (now - lastGrowMs > 60000) {
            AppLog.w('play', '等待下载超时(60s无增长)，断开流: start=$start pos=$pos');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 80));
          continue;
        }
        // 单次最多 256KB；带 Range 上界时不超发（精确匹配 Content-Length）
        var toRead = (len - pos).clamp(1, 256 * 1024);
        if (end >= 0 && pos + toRead > end + 1) toRead = end + 1 - pos;
        final data = await raf.read(toRead);
        if (data.isEmpty) {
          if (isFinished()) break;
          await Future.delayed(const Duration(milliseconds: 80));
          continue;
        }
        pos += data.length;
        yield data;
      }
    } finally {
      await raf.close();
    }
  }
}
