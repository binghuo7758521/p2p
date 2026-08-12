import 'dart:async';
import 'dart:io';

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
/// 供 video_player 在线播放。
class VideoPlayServer {
  HttpServer? _server;

  /// 启动本地 HTTP 服务器（绑定 127.0.0.1 随机端口）。
  /// [file] 为正在被写入的临时视频文件；
  /// [isFinished] 返回下载是否已完成（到达 EOF 且完成后流才结束）。
  /// 返回服务器端口。
  Future<int> start(
    File file, {
    required bool Function() isFinished,
    required String mime,
  }) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) {
      _handle(req, file, isFinished, mime).catchError((e) {
        AppLog.w('play', '播放请求处理异常: ${req.uri.path} $e');
        try {
          req.response.statusCode = 500;
          req.response.close();
        } catch (_) {}
      });
    });
    AppLog.i('play', '本地播放服务器已绑定: 127.0.0.1:${_server!.port} (文件=${file.path})');
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
  ) async {
    final res = req.response;
    if (req.uri.path != '/play') {
      AppLog.w('play', '未知请求路径: ${req.uri.path}');
      res.statusCode = 404;
      await res.close();
      return;
    }

    // 解析 Range 头（ExoPlayer 等播放器会请求 bytes=start-end）
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final total = await file.length();
    var start = 0;
    var end = total - 1;
    var hasRange = false;
    if (range != null && range.startsWith('bytes=')) {
      final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (m != null) {
        hasRange = true;
        start = int.tryParse(m.group(1) ?? '') ?? 0;
        final endPart = int.tryParse(m.group(2) ?? '');
        end = endPart ?? (total > 0 ? total - 1 : start);
        if (end < start) end = start;
      }
    }
    AppLog.i('play',
        '播放请求: range=${range ?? '无'} => ${hasRange ? '206' : '200'} start=$start end=$end total=$total (文件当前大小=${await file.length()})');

    res.statusCode = hasRange ? 206 : 200;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (hasRange) {
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }
    res.headers.set(HttpHeaders.contentTypeHeader, mime);
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

    // 流式读取：文件未写完时等待写入（边下边播），完成后读到 EOF 结束
    var sent = 0;
    await res.addStream(_readRange(file, start, isFinished)
        .map((d) { sent += d.length; return d; }));
    await res.close();
    AppLog.i('play', '播放响应完成: 发送$sent字节 (请求start=$start)');
  }

  Stream<List<int>> _readRange(
    File file,
    int start,
    bool Function() isFinished,
  ) async* {
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      var pos = start;
      while (true) {
        final len = await file.length();
        if (pos >= len) {
          if (isFinished()) break; // 下载完成且已读到末尾
          await Future.delayed(const Duration(milliseconds: 80));
          continue;
        }
        final toRead = (len - pos).clamp(0, 256 * 1024);
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
