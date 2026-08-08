import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';
import 'protocol.dart';
import 'rtc_service.dart';
import 'signaling_service.dart';
import 'video_play_service.dart';

/// 连接状态
enum ConnectState { idle, connecting, paired, peerConnected, error, lost }

/// 上传文件名冲突（等待用户决策）
class UploadConflict {
  final String fileName;
  final String requestId;

  const UploadConflict({required this.fileName, required this.requestId});
}

/// 断点续传记录：上传
class ResumeUpload {
  final String requestId;
  final String fileName;
  final String localPath;
  final int offset; // 已发送字节（握手后以电脑端 accept.offset 为准）
  final String subPath; // 上传目标目录

  const ResumeUpload({
    required this.requestId,
    required this.fileName,
    required this.localPath,
    required this.offset,
    required this.subPath,
  });
}

/// 断点续传记录：下载
class ResumeDownload {
  final String path; // 电脑端文件路径
  final String fileName;
  final int offset; // 已接收字节

  const ResumeDownload({
    required this.path,
    required this.fileName,
    required this.offset,
  });
}

/// 上次成功配对的信息（用于下次自动直连）
class PairInfo {
  final String server;
  final String code;

  const PairInfo({required this.server, required this.code});

  factory PairInfo.fromJson(Map<String, dynamic> json) => PairInfo(
        server: json['server'] as String? ?? '',
        code: json['code'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'server': server, 'code': code};
}

/// 全局控制器：编排信令、WebRTC 数据通道与文件传输
class AppController extends ChangeNotifier {
  final SignalingService _signaling = SignalingService();
  final RtcService _rtc = RtcService();

  // ── 连接状态 ──────────────────────────────────────────
  ConnectState state = ConnectState.idle;
  String? errorMessage;
  String? hostName;

  // ── 浏览状态 ──────────────────────────────────────────
  final List<String> _path = []; // 面包屑名称栈
  final List<String> _dirStack = []; // 每层目录的完整路径栈（支持我的电脑模式）
  List<FileEntry> files = [];
  bool listLoading = false;
  String? listError;
  String dirPath = '';

  // ── 传输状态 ──────────────────────────────────────────
  final List<TransferItem> transfers = [];
  String? activeDownloadName;
  int activeDownloadSize = 0;
  int activeDownloadBytes = 0;

  // ── 上传目标目录与冲突决策 ─────────────────────────────
  String uploadDirPath = ''; // 相对共享目录，空=根目录
  List<FileEntry> uploadDirs = [];
  bool uploadDirLoading = false;
  UploadConflict? pendingConflict; // 待用户决策的重名冲突
  Completer<String>? _uploadGate; // 等待电脑端 accept/conflict
  final Map<String, Completer<String>> _conflictWaiters = {};
  String? _applyAllAction; // 本次批次「所有文件」统一处理方式，置空表示逐文件弹窗
  bool _acceptArrived = false; // 冲突决策期间 accept 已到达：下次握手直接通过

  // 内部下载状态
  IOSink? _recvSink;
  File? _recvFile;
  int _recvExpected = 0;
  int _recvBytes = 0;
  int _recvStartMs = 0;
  String? _recvFileName;

  // 在线播放状态
  bool _playMode = false; // 当前下载是否用于在线播放
  File? _playFile; // 播放临时文件（边下边播）
  final VideoPlayServer _playServer = VideoPlayServer();
  String? playUrl; // 本地播放地址，null=未就绪
  bool playFinished = false; // 视频已全部下载完成
  String? playError; // 播放/下载错误信息

  // 内部上传状态
  bool uploading = false;
  int _uploadBytes = 0;
  int _uploadStartMs = 0;

  // ── 自动重连与断点续传 ──────────────────────────────────
  String? _lastServer; // 最近一次连接的服务器（自动重连用）
  String? _lastCode; // 最近一次配对码
  bool _manualDisconnect = false; // 用户主动断开：不再自动重连
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  final List<ResumeUpload> _resumeUploads = []; // 断线时中断的上传队列
  ResumeDownload? _resumeDownload; // 断线时中断的下载
  bool _resuming = false; // 防止重连恢复逻辑重复执行
  int _acceptOffset = 0; // 电脑端 accept 回包的实际续传起点

  // ── 初始化 ────────────────────────────────────────────
  AppController() {
    _rtc.sendSignal = _signaling.sendSignal;
    _signaling.onJoined = _onJoined;
    _signaling.onError = (reason) {
      state = ConnectState.error;
      errorMessage = reason;
      notifyListeners();
    };
    _signaling.onSignal = (signal) => _rtc.handleSignal(signal);
    _signaling.onConnectError = (msg) {
      state = ConnectState.error;
      errorMessage = '无法连接服务器: $msg';
      notifyListeners();
    };
    _signaling.onPeerDisconnected = _onPeerLost;
    _rtc.messages.listen(_onChannelMessage);
    _rtc.stateChanges.listen((open) {
      if (open && state != ConnectState.peerConnected) {
        state = ConnectState.peerConnected;
        notifyListeners();
        _requestFileList();
        // 自动重连成功（数据通道恢复）：续传断线时中断的传输
        _resumePendingTransfers();
      } else if (!open && state == ConnectState.peerConnected) {
        _onPeerLost();
      }
    });
  }

  // ── 连接流程 ──────────────────────────────────────────
  Future<void> connect(String serverUrl, String pairCode) async {
    _lastServer = serverUrl.replaceAll(RegExp(r'/$'), '');
    _lastCode = pairCode.trim();
    _manualDisconnect = false;
    state = ConnectState.connecting;
    errorMessage = null;
    notifyListeners();

    try {
      await _rtc.init();
      await _signaling.connect(
        serverUrl: _lastServer!,
        pairCode: _lastCode!,
        deviceName: 'Android',
      );
    } catch (e) {
      state = ConnectState.error;
      errorMessage = '初始化失败: $e';
      notifyListeners();
    }
  }

  void _onJoined(Map<String, dynamic> data) {
    // 服务器下发的 TURN 中继凭证（直连失败时的兜底通道）
    final turn = data['turn'];
    _rtc.turnConfig = turn is Map
        ? Map<String, dynamic>.from(turn)
        : null;
    final hostInfo = data['hostInfo'];
    hostName = hostInfo is Map
        ? hostInfo['name']?.toString() ?? '电脑'
        : data['name']?.toString() ?? '电脑';
    state = ConnectState.paired;
    notifyListeners();
  }

  void _onPeerLost() {
    // lost 状态说明已在自动重连中（信令/RTC 重建会再次触发断开回调），不再重复处理
    if (state == ConnectState.idle || state == ConnectState.lost) return;
    if (_manualDisconnect) {
      state = ConnectState.idle;
      errorMessage = null;
      notifyListeners();
      return;
    }
    // 记录断点（上传队列 / 下载进度），供自动重连后续传
    _captureResumeState();
    _cleanupReceive(); // 保留磁盘 .part 文件供续传
    state = ConnectState.lost;
    errorMessage = '与电脑端的连接已断开，正在自动重连…';
    notifyListeners();
    _startAutoReconnect();
  }

  /// 记录断线时未完成的传输（用于重连后自动续传）
  void _captureResumeState() {
    for (final t in transfers) {
      if (t.status != 'transferring') continue;
      if (t.direction == 'upload' && t.localPath != null) {
        _resumeUploads.add(ResumeUpload(
          requestId: t.id,
          fileName: t.fileName,
          localPath: t.localPath!,
          offset: t.transferred,
          subPath: uploadDirPath,
        ));
      }
    }
    // 下载（在线播放模式不自动续传）
    final recvName = _recvFileName;
    if (recvName != null && !_playMode && _recvBytes > 0 && _recvExpected > 0) {
      final dl = transfers
          .where((x) => x.fileName == recvName && x.direction == 'download')
          .toList();
      if (dl.isNotEmpty && dl.first.remotePath != null) {
        _resumeDownload = ResumeDownload(
          path: dl.first.remotePath!,
          fileName: recvName,
          offset: _recvBytes,
        );
      }
    }
  }

  /// 自动重连循环：指数退避（1s→30s），重连成功后等待电脑端重新 offer
  void _startAutoReconnect() {
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectLoop();
  }

  Future<void> _reconnectLoop() async {
    final server = _lastServer;
    final code = _lastCode;
    if (server == null || code == null) return;
    while (state == ConnectState.lost && !_manualDisconnect) {
      final delay = _reconnectAttempts == 0
          ? 1
          : (_reconnectAttempts > 5 ? 30 : 2 * _reconnectAttempts);
      _reconnectAttempts++;
      await Future.delayed(Duration(seconds: delay));
      if (state != ConnectState.lost || _manualDisconnect) return;
      try {
        // 重建信令连接 + 重置 WebRTC（旧 PeerConnection 已失效，等待新 offer）
        await _rtc.init();
        await _signaling.connect(
          serverUrl: server,
          pairCode: code,
          deviceName: 'Android',
        );
        // 连接成功后 onConnect 自动 client:join；joined → paired 后电脑端发 offer
        // 若 join 失败（配对码暂不可用，如电脑端重连中）继续循环重试
      } catch (_) {
        // 网络错误，继续下一轮
      }
    }
  }

  /// 重连成功（数据通道恢复）后：自动续传中断的传输
  Future<void> _resumePendingTransfers() async {
    if (_resuming) return;
    _resuming = true;
    try {
      while (_resumeUploads.isNotEmpty) {
        final r = _resumeUploads.removeAt(0);
        final ok = await _resumeUpload(r);
        if (!ok) break; // 续传失败：停止后续（避免死循环）
      }
      final d = _resumeDownload;
      if (d != null) {
        _resumeDownload = null;
        await _resumeDownloadFile(d);
      }
    } finally {
      _resuming = false;
    }
  }

  /// 续传单个上传文件：携带 offset 重新握手，以电脑端 accept.offset 为准定位
  Future<bool> _resumeUpload(ResumeUpload r) async {
    if (!_rtc.isOpen) return false;
    TransferItem? t;
    for (final x in transfers) {
      if (x.id == r.requestId) {
        t = x;
        break;
      }
    }
    if (t == null || t.status != 'error') return true; // 记录已结束，跳过
    try {
      final f = File(r.localPath);
      final size = await f.length();
      // 源文件大小变化：从头续传（offset 归零、总大小按新值）
      var startOffset = r.offset;
      if (size != t.total) {
        t.total = size;
        startOffset = 0;
      }
      _uploadBytes = 0;
      _uploadStartMs = DateTime.now().millisecondsSinceEpoch;
      t.status = 'transferring';
      _acceptOffset = 0;
      final totalChunks = size == 0 ? 0 : (size / kChunkSize).ceil();

      _rtc.sendJson({
        'type': 'file:upload',
        'fileName': r.fileName,
        'fileSize': size,
        'totalChunks': totalChunks,
        'subPath': r.subPath,
        'requestId': r.requestId,
        if (startOffset > 0) 'offset': startOffset,
      });

      final decision =
          await _waitUploadDecision(r.fileName, const Duration(seconds: 3));
      if (decision == 'conflict') {
        // 重连后出现重名冲突（上次传输期间正式文件已存在）：按覆盖处理
        _rtc.sendJson({
          'type': 'file:conflict-resolve',
          'fileName': r.fileName,
          'requestId': r.requestId,
          'action': 'overwrite',
        });
        await _waitUploadDecision(r.fileName, const Duration(seconds: 3));
      } else if (decision == 'busy' || decision == 'rejected') {
        t.status = 'error';
        notifyListeners();
        return false;
      }

      // 以电脑端实际续传起点为准（磁盘 .part 大小）；无 offset 表示从头
      final start = _acceptOffset > 0 ? _acceptOffset : 0;
      t.transferred = start;
      notifyListeners();

      final raf = await f.open();
      try {
        if (start > 0) await raf.setPosition(start);
        final buf = Uint8List(kChunkSize);
        while (t.status == 'transferring') {
          final n = await raf.readInto(buf);
          if (n <= 0) break;
          while (_rtc.bufferedAmount > kBackpressureLimit &&
              t.status == 'transferring') {
            await Future.delayed(const Duration(milliseconds: 5));
          }
          if (t.status != 'transferring') break;
          _rtc.sendBinary(
              n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
          _uploadBytes += n;
          t.transferred = start + _uploadBytes;
          t.update(t.transferred,
              DateTime.now().millisecondsSinceEpoch - _uploadStartMs);
          notifyListeners();
        }
      } finally {
        await raf.close();
      }

      if (t.status == 'transferring') {
        _rtc.sendJson({'type': 'file-complete'});
        while (t.status == 'transferring') {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      return true;
    } catch (e) {
      debugPrint('续传失败 ${r.fileName}: $e');
      if (t.status == 'transferring') {
        t.status = 'error';
        notifyListeners();
      }
      return false;
    }
  }

  /// 续传下载：携带 offset 请求电脑端从偏移发送，本地 .part 追加写入
  Future<void> _resumeDownloadFile(ResumeDownload d) async {
    if (!_rtc.isOpen) return;
    // 续传起点以本地磁盘 .part 实际大小为准（断线后内存记录可能过期）
    var offset = d.offset;
    try {
      final dir = await AppController.downloadDir();
      final safe =
          d.fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final part = File('${dir.path}/$safe.p2p.part');
      if (part.existsSync()) {
        final len = await part.length();
        if (len > 0) offset = len;
      }
    } catch (_) {}
    _rtc.sendJson({
      'type': 'file:download',
      'path': d.path,
      'fileName': d.fileName,
      if (offset > 0) 'offset': offset,
    });
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _resumeUploads.clear();
    _resumeDownload = null;
    _cleanupReceive();
    _signaling.dispose();
    await _rtc.dispose();
    state = ConnectState.idle;
    hostName = null;
    files = [];
    dirPath = '';
    _path.clear();
    _dirStack.clear();
    uploadDirPath = '';
    uploadDirs = [];
    uploadDirLoading = false;
    pendingConflict = null;
    _applyAllAction = null;
    _acceptArrived = false;
    _uploadGate?.complete('accept'); // 解除可能的握手等待
    _uploadGate = null;
    for (final c in _conflictWaiters.values) {
      if (!c.isCompleted) c.complete('skip');
    }
    _conflictWaiters.clear();
    notifyListeners();
  }

  // ── 浏览 ──────────────────────────────────────────────
  void _requestFileList() {
    if (_rtc.isOpen) {
      _rtc.sendJson({'type': 'file:list', 'path': dirPath});
    }
  }

  Future<void> requestFileList() async {
    listLoading = true;
    listError = null;
    notifyListeners();
    _requestFileList();
  }

  /// 进入目录：优先使用电脑端返回的完整路径（我的电脑模式为绝对路径）
  void openDir(FileEntry entry) {
    _path.add(entry.name);
    _dirStack.add(dirPath); // 记录进入前的父目录路径
    dirPath = entry.path ??
        (dirPath.isEmpty ? entry.name : '$dirPath/${entry.name}');
    _requestFileList();
    listLoading = true;
    listError = null;
    notifyListeners();
  }

  void navigateTo(int depth) {
    if (depth < 0) {
      _path.clear();
      _dirStack.clear();
      dirPath = '';
    } else {
      _path.removeRange(depth + 1, _path.length);
      _dirStack.removeRange(depth + 1, _dirStack.length);
      dirPath = _dirStack.isEmpty ? '' : _dirStack.last;
    }
    _requestFileList();
    listLoading = true;
    listError = null;
    notifyListeners();
  }

  // ── 上传目标目录 ──────────────────────────────────────
  void _requestUploadDirs() {
    if (_rtc.isOpen) {
      _rtc.sendJson(
          {'type': 'file:list', 'path': uploadDirPath, 'requestId': 'upload'});
    }
  }

  /// 刷新上传目标目录列表
  void refreshUploadDirs() {
    uploadDirLoading = true;
    uploadDirs = [];
    notifyListeners();
    _requestUploadDirs();
  }

  /// 进入上传目标子目录
  void openUploadDir(FileEntry entry) {
    uploadDirPath = entry.path ??
        (uploadDirPath.isEmpty ? entry.name : '$uploadDirPath/${entry.name}');
    uploadDirLoading = true;
    uploadDirs = [];
    notifyListeners();
    _requestUploadDirs();
  }

  /// 返回上传目标上级目录
  void navigateUploadDir(int depth) {
    final segs = uploadDirPath.split('/').where((s) => s.isNotEmpty).toList();
    uploadDirPath = segs.take(depth + 1).join('/');
    uploadDirLoading = true;
    uploadDirs = [];
    notifyListeners();
    _requestUploadDirs();
  }

  // ── 下载 ──────────────────────────────────────────────
  Future<void> downloadFile(FileEntry entry) async {
    if (!_rtc.isOpen || entry.isDirectory) return;
    final path = entry.path ??
        (dirPath.isEmpty ? entry.name : '$dirPath/${entry.name}');
    _rtc.sendJson({
      'type': 'file:download',
      'path': path,
      'fileName': entry.name,
    });
  }

  /// 在线播放视频：边下边播，无需等待下载完成
  Future<void> playVideo(FileEntry entry) async {
    if (!_rtc.isOpen || entry.isDirectory) return;
    _playMode = true;
    playFinished = false;
    playUrl = null;
    playError = null;
    notifyListeners();
    final path = entry.path ??
        (dirPath.isEmpty ? entry.name : '$dirPath/${entry.name}');
    _rtc.sendJson({
      'type': 'file:download',
      'path': path,
      'fileName': entry.name,
    });
  }

  /// 结束播放（播放页关闭时调用）：停止本地服务器并清理临时文件
  Future<void> stopPlay() async {
    _playMode = false;
    playFinished = false;
    playUrl = null;
    playError = null;
    final pf = _playFile;
    _playFile = null;
    await _playServer.stop();
    if (pf != null) {
      try {
        if (await pf.exists()) await pf.delete();
      } catch (_) {}
    }
  }

  void _startDownload(ControlMessage msg) {
    final fileName = msg.data['fileName']?.toString() ?? 'unknown';
    final fileSize = (msg.data['fileSize'] as num?)?.toInt() ?? 0;
    _recvStartMs = DateTime.now().millisecondsSinceEpoch;

    // 准备接收状态：创建保存文件与写入流
    _recvFileName = fileName;
    _recvExpected = fileSize;
    _recvBytes = 0;
    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (_playMode) {
      // 播放模式：写入临时文件，并启动本地流媒体服务器（边下边播）
      getTemporaryDirectory().then((dir) async {
        if (_recvFileName != fileName) return; // 已被新传输替换
        final f = File(
            '${dir.path}/p2p_play_${DateTime.now().millisecondsSinceEpoch}_$safeName');
        try {
          _recvFile = f;
          _playFile = f;
          _recvSink = f.openWrite();
          final port = await _playServer.start(
            f,
            isFinished: () => playFinished,
            mime: mimeForVideo(fileName),
          );
          playUrl = 'http://127.0.0.1:$port/play';
          notifyListeners();
        } catch (e) {
          debugPrint('启动播放服务器失败: $e');
          playError = '播放服务启动失败: $e';
          _recvSink = null;
          notifyListeners();
        }
      });
    } else {
      AppController.downloadDir().then((dir) async {
        if (_recvFileName != fileName) return; // 已被新传输替换
        // 断点续传：统一写入 .p2p.part 临时文件（完成后重命名正式名）；
        // 基准偏移取「电脑端发送起点」与「本地 .part 实际大小」的较大者，
        // 避免两端数据错位；电脑端起点更早时本地作废从头重写
        final reqOffset = (msg.data['offset'] as num?)?.toInt() ?? 0;
        final part = File('${dir.path}/$safeName.p2p.part');
        var base = 0;
        try {
          if (part.existsSync()) base = await part.length();
        } catch (_) {}
        if (reqOffset < base) {
          base = 0;
          try {
            await part.delete();
          } catch (_) {}
        } else if (reqOffset > base) {
          base = reqOffset;
        }
        try {
          _recvFile = part;
          _recvSink = part.openWrite(
              mode: base > 0 ? FileMode.append : FileMode.write);
          _recvBytes = base;
          if (_recvBytes > 0) {
            for (final item in transfers) {
              if (item.fileName == fileName) {
                item.transferred = _recvBytes;
              }
            }
            activeDownloadBytes = _recvBytes;
          }
        } catch (e) {
          debugPrint('创建下载文件失败: $e');
          _recvSink = null;
        }
      });
    }

    _addTransfer(fileName, 'download', fileSize);
    activeDownloadName = fileName;
    activeDownloadSize = fileSize;
    activeDownloadBytes = 0;
    notifyListeners();
  }

  Future<void> _finalizeDownload() async {
    final sink = _recvSink;
    _recvSink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }

    final success = _recvFile != null && _recvBytes == _recvExpected;
    final name = _recvFileName ?? '';
    final playMode = _playMode;
    if (success && _recvFile != null && !playMode) {
      // 普通下载：.part 重命名为正式文件后再弹出系统分享；
      // 播放模式直接保留临时文件供播放器使用
      try {
        final dir = await AppController.downloadDir();
        final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final finalFile = File('${dir.path}/$safeName');
        var target = finalFile;
        if (await target.exists()) {
          // 同名正式文件已存在：自动追加序号避免覆盖
          final dot = safeName.lastIndexOf('.');
          final base = dot > 0 ? safeName.substring(0, dot) : safeName;
          final ext = dot > 0 ? safeName.substring(dot) : '';
          for (var i = 1; ; i++) {
            final candidate = File('${dir.path}/$base ($i)$ext');
            if (!await candidate.exists()) {
              target = candidate;
              break;
            }
          }
        }
        await _recvFile!.rename(target.path);
        await SharePlus.instance.share(
          ShareParams(files: [XFile(target.path)], text: '已从电脑下载: $name'),
        );
      } catch (_) {}
    } else if (!success && _recvFile != null && !playMode) {
      // 下载失败：清理不完整 .part，避免残留干扰后续续传起点判断
      try {
        if (await _recvFile!.exists()) await _recvFile!.delete();
      } catch (_) {}
    }

    final t = transfers.where((x) => x.fileName == name).toList();
    for (final item in t) {
      item.status = success ? 'done' : 'error';
      item.transferred = item.total;
    }
    if (!success) {
      errorMessage = '下载失败: 文件不完整 ($_recvBytes/$_recvExpected)';
      if (playMode) playError = '下载中断，文件不完整';
    }

    // 播放模式：标记下载完成（流式服务器据此结束数据流）
    if (playMode) {
      playFinished = true;
      if (!success) playError = '下载中断，文件不完整';
    }

    // 回复电脑端确认结果
    if (_rtc.isOpen) {
      _rtc.sendJson({'type': 'file-ack', 'fileName': name, 'success': success});
    }
    activeDownloadName = null;
    activeDownloadSize = 0;
    activeDownloadBytes = 0;
    // 播放模式：保留 _playFile 供播放器继续读取，播放结束由 stopPlay 清理
    if (!playMode) _recvFile = null;
    _recvFileName = null;
    _recvExpected = 0;
    _recvBytes = 0;
    if (playMode) _playMode = false;
    notifyListeners();
  }

  // ── 上传 ──────────────────────────────────────────────
  /// 上传一组文件，返回成功文件数。
  /// 每个文件先与电脑端握手（接受/重名冲突决策），确认后才发送数据；
  /// 等待电脑端对本次所有文件返回确认后才解锁，避免重复提交。
  Future<int> startUpload(List<PlatformFile> picked) async {
    if (!_rtc.isOpen || picked.isEmpty || uploading) return 0;

    uploading = true;
    notifyListeners();
    final ids = <String>[];

    for (final file in picked) {
      TransferItem? t;
      try {
        if (file.path == null) continue; // 无路径文件无法流式读取
        final f = File(file.path!);
        final size = await f.length();
        _uploadBytes = 0;
        _uploadStartMs = DateTime.now().millisecondsSinceEpoch;

        t = _addTransfer(file.name, 'upload', size);
        ids.add(t.id);
        final totalChunks = size == 0 ? 0 : (size / kChunkSize).ceil();

        _rtc.sendJson({
          'type': 'file:upload',
          'fileName': file.name,
          'fileSize': size,
          'totalChunks': totalChunks,
          'subPath': uploadDirPath,
          'requestId': t.id,
        });

        // 握手：等待电脑端 accept/conflict（兼容旧电脑端：超时直接发送）
        final decision =
            await _waitUploadDecision(file.name, const Duration(seconds: 2));
        if (decision == 'conflict') {
          // 文件名冲突：弹出决策对话框等待用户选择
          final action = await _waitConflictResolve(file.name, t.id);
          if (action == 'skip') {
            try {
              _rtc.sendJson({'type': 'file-complete'});
            } catch (_) {}
            // 等电脑端回 ack(skipped) 后再处理下一个文件
            if (t.status == 'transferring') {
              while (t.status == 'transferring') {
                await Future.delayed(const Duration(milliseconds: 100));
              }
            }
            continue; // 电脑端回 ack(skipped) 后状态置为已跳过
          }
          // overwrite / rename：电脑端随后发送 accept
          await _waitUploadDecision(file.name, const Duration(seconds: 3));
        } else if (decision == 'busy' || decision == 'rejected') {
          // 电脑端拒绝了本次握手（已有其他传输等）：不发送数据块，标记失败
          if (t.status == 'transferring') {
            t.status = 'error';
            notifyListeners();
          }
          continue;
        }

        final raf = await f.open();
        try {
          final buf = Uint8List(kChunkSize);
          while (true) {
            // 发送期间电脑端拒绝或通道断开：停止本次发送，不再补发数据块
            if (t.status != 'transferring') break;
            final n = await raf.readInto(buf);
            if (n <= 0) break;
            // 背压控制：等待发送缓冲低于阈值（期间被拒绝则放弃）
            while (_rtc.bufferedAmount > kBackpressureLimit &&
                t.status == 'transferring') {
              await Future.delayed(const Duration(milliseconds: 5));
            }
            if (t.status != 'transferring') break;
            _rtc.sendBinary(
                n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
            _uploadBytes += n;
            t.transferred = _uploadBytes;
            t.update(_uploadBytes,
                DateTime.now().millisecondsSinceEpoch - _uploadStartMs);
            notifyListeners();
          }
        } finally {
          await raf.close();
        }

        if (t.status == 'transferring') {
          _rtc.sendJson({'type': 'file-complete'});
          // 串行传输：等电脑端确认后再传下一个文件，避免多文件并发发送
          // 导致电脑端接收状态串扰（上一个文件未结束时新请求被 busy 拒绝）
          while (t.status == 'transferring') {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      } catch (e) {
        // 通道异常/读取失败：标记该文件失败，继续下一个
        debugPrint('上传失败 ${file.name}: $e');
        if (t != null && t.status == 'transferring') {
          t.status = 'error';
          notifyListeners();
        }
      }
    }

    // 等待电脑端对本次所有文件返回确认（断开时状态会被置为 error，轮询自然结束）；
    // 15 分钟超时兜底：电脑端意外漏回 ack 时不至于永久卡「上传中」
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    while (transfers.any(
        (t) => ids.contains(t.id) && t.status == 'transferring')) {
      if (DateTime.now().isAfter(deadline)) {
        for (final id in ids) {
          TransferItem? t;
          for (final x in transfers) {
            if (x.id == id) {
              t = x;
              break;
            }
          }
          if (t != null && t.status == 'transferring') {
            t.status = 'error';
            errorMessage = '上传超时，电脑端未确认结果: ${t.fileName}';
          }
        }
        break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    uploading = false;
    _applyAllAction = null; // 批次结束清除「所有文件」统一处理方式
    notifyListeners();
    return ids
        .where((id) =>
            transfers.any((t) => t.id == id && t.status == 'done'))
        .length;
  }

  /// 等待电脑端对当前上传文件的 accept/conflict 决策；超时视为 accept（兼容旧电脑端）
  Future<String> _waitUploadDecision(String name, Duration timeout) async {
    // 重名决策期间 accept 已到达（_uploadGate 已清空，消息被标记）：直接通过
    if (_acceptArrived) {
      _acceptArrived = false;
      return 'accept';
    }
    final gate = Completer<String>();
    _uploadGate = gate;
    try {
      return await gate.future.timeout(timeout, onTimeout: () => 'accept');
    } finally {
      _uploadGate = null;
    }
  }

  /// 文件名冲突：通知 UI 弹窗，等待用户决策（overwrite/rename/skip）
  Future<String> _waitConflictResolve(String name, String requestId) async {
    // 用户已勾选「对本次上传的其他重名文件同样处理」：直接应用，不再弹窗
    final applyAll = _applyAllAction;
    if (applyAll != null) return applyAll;
    final completer = _conflictWaiters[requestId] = Completer<String>();
    pendingConflict = UploadConflict(fileName: name, requestId: requestId);
    notifyListeners();
    try {
      return await completer.future;
    } finally {
      _conflictWaiters.remove(requestId);
    }
  }

  /// 用户对重名冲突做出决策；applyAll 为 true 时本次批次后续冲突不再弹窗，
  /// 统一按该方式处理
  void resolveConflict(String action, {bool applyAll = false}) {
    final req = pendingConflict;
    if (req == null) return;
    if (applyAll) _applyAllAction = action;
    pendingConflict = null;
    _rtc.sendJson({
      'type': 'file:conflict-resolve',
      'fileName': req.fileName,
      'requestId': req.requestId,
      'action': action,
    });
    _conflictWaiters.remove(req.requestId)?.complete(action);
    notifyListeners();
  }

  void _handleUploadAck(ControlMessage msg) {
    final success = msg.data['success'] == true;
    final reason = msg.data['reason']?.toString();
    // 优先按 requestId 精确匹配（多文件同名时避免错标）；
    // 旧电脑端无 requestId 时回退为按文件名匹配最近一条进行中的上传记录
    TransferItem? item;
    final rid = msg.data['requestId']?.toString();
    if (rid != null && rid.isNotEmpty) {
      for (final x in transfers) {
        if (x.id == rid) {
          item = x;
          break;
        }
      }
    }
    if (item == null) {
      final name = msg.data['fileName']?.toString() ?? '';
      final list = transfers
          .where((x) =>
              x.fileName == name &&
              x.direction == 'upload' &&
              x.status == 'transferring')
          .toList();
      if (list.isNotEmpty) item = list.first;
    }
    if (item == null) return;
    if (reason == 'skipped') {
      item.status = 'skipped';
    } else {
      item.status = success ? 'done' : 'error';
    }
    if (success || reason == 'skipped') item.transferred = item.total;
    // 握手等待期间收到失败回包：立即结束等待（返回 busy/rejected），
    // 避免手机端超时后仍误发数据块，造成电脑端缓存串扰
    if (!success && _uploadGate != null) {
      final g = _uploadGate!;
      _uploadGate = null;
      if (!g.isCompleted) {
        g.complete(reason == 'busy' ? 'busy' : 'rejected');
      }
    }
    if (!success && reason != 'skipped' && _rtc.isOpen) {
      switch (reason) {
        case 'no-dir':
          errorMessage =
              '电脑端未找到保存目录（「我的电脑」根目录无法直接保存），请先在手机端进入具体文件夹再上传';
          break;
        case 'busy':
          errorMessage = '电脑端有其他传输正在进行，请稍后重试: ${item.fileName}';
          break;
        case 'size-mismatch':
          errorMessage =
              '文件传输不完整，电脑端保存失败: ${item.fileName}';
          break;
        default:
          errorMessage = '电脑端保存文件失败: ${item.fileName}';
      }
    }
    notifyListeners();
  }

  // ── 数据通道消息分发 ──────────────────────────────────
  void _onChannelMessage(dynamic data) {
    final msg = tryParseControlMessage(data);
    if (msg == null) {
      _onBinary(data as Uint8List);
      return;
    }
    switch (msg.type) {
      case 'file-list-result':
        final requestId = msg.data['requestId']?.toString() ?? 'browse';
        final parsed = (msg.data['files'] as List? ?? [])
            .whereType<Map>()
            .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        if (requestId == 'upload') {
          uploadDirs = parsed;
          uploadDirLoading = false;
        } else {
          files = parsed;
          listError = msg.data['error']?.toString();
          listLoading = false;
        }
        notifyListeners();
        break;
      case 'file:accept':
        // 电脑端确认接收；记录实际续传起点（以电脑端磁盘 .part 大小为准）
        final off = msg.data['offset'];
        if (off is num) _acceptOffset = off.toInt();
        if (_uploadGate != null) {
          _uploadGate!.complete('accept');
        } else {
          // 冲突决策期间到达：_uploadGate 已清空，标记供下次握手直接通过
          _acceptArrived = true;
        }
        break;
      case 'file:conflict':
        // 电脑端发现同名文件，等待用户决策
        _uploadGate?.complete('conflict');
        break;
      case 'file-meta':
        _startDownload(msg);
        break;
      case 'file-complete':
        _finalizeDownload();
        break;
      case 'file-ack':
        _handleUploadAck(msg);
        break;
    }
  }

  void _onBinary(Uint8List chunk) {
    final sink = _recvSink;
    if (sink == null) return;
    sink.add(chunk);
    _recvBytes += chunk.length;
    final t = transfers.where((x) => x.fileName == _recvFileName).toList();
    for (final item in t) {
      item.update(_recvBytes,
          DateTime.now().millisecondsSinceEpoch - _recvStartMs);
    }
    activeDownloadBytes = _recvBytes;
    notifyListeners();
  }

  // ── 内部工具 ──────────────────────────────────────────
  TransferItem _addTransfer(String name, String direction, int total) {
    final t = TransferItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: name,
      direction: direction,
      total: total,
      startTime: DateTime.now(),
    );
    transfers.insert(0, t);
    return t;
  }

  void _cleanupReceive() {
    final sink = _recvSink;
    _recvSink = null;
    if (sink != null) {
      try {
        sink.close();
      } catch (_) {}
    }
    _recvFile = null;
    _recvFileName = null;
    _recvExpected = 0;
    _recvBytes = 0;
    activeDownloadName = null;
    activeDownloadBytes = 0;
    activeDownloadSize = 0;
    for (final t in transfers) {
      if (t.status == 'transferring') t.status = 'error';
    }
  }

  /// 保存路径（应用文档目录下 P2P 下载）
  static Future<Directory> downloadDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/P2P下载');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 配对信息存储文件（应用私有目录）
  static Future<File> _pairInfoFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/pair_info.json');
  }

  /// 保存上次成功配对的信息（下次启动自动直连）
  Future<void> savePairInfo(String server, String code) async {
    try {
      final f = await _pairInfoFile();
      await f.writeAsString(
          jsonEncode(PairInfo(server: server, code: code).toJson()));
    } catch (_) {
      // 保存失败不影响主流程
    }
  }

  /// 读取上次配对信息，无记录返回 null
  Future<PairInfo?> loadPairInfo() async {
    try {
      final f = await _pairInfoFile();
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, dynamic>) {
        final info = PairInfo.fromJson(json);
        if (info.server.isNotEmpty && info.code.isNotEmpty) return info;
      }
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _cleanupReceive();
    _signaling.dispose();
    _rtc.dispose();
    super.dispose();
  }
}
