import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'host_service.dart';
import 'models.dart';
import 'protocol.dart';

/// 电脑端连接状态
enum HostState {
  idle, // 未连接
  registered, // 已注册（配对码就绪，等待手机）
  peerConnected, // 手机已连接
  lost, // 连接断开
}

/// 电脑端控制器：编排信令、WebRTC、共享目录与文件传输
class HostController extends ChangeNotifier {
  final HostService _service = HostService();

  HostState state = HostState.idle;
  String pairCode = '';
  String? errorMessage;
  String? clientName;
  String serverUrl = 'http://127.0.0.1:3000';

  // ── 共享目录 ────────────────────────────────────────────
  Directory? sharedDir; // 手动模式下的共享根目录
  bool myComputerMode = true; // 默认共享「我的电脑」（全部磁盘 + 桌面等）
  List<FileEntry> localFiles = [];
  String localPath = ''; // 我的电脑模式为绝对路径，手动模式为相对共享目录路径

  // ── 传输记录 ────────────────────────────────────────────
  final List<TransferItem> transfers = [];

  // 接收上传状态
  File? _recvFile;
  IOSink? _recvSink;
  TransferItem? _currentUploadItem; // 当前上传的传输记录（完成时按此标记，避免串文件）
  int _recvExpected = 0;
  int _recvBytes = 0;
  int _recvStartMs = 0;
  String? _recvFileName;
  String _recvRequestId = ''; // 手机端上传请求唯一标识，回包携带以精确匹配
  String _recvSubPath = '';
  bool _conflictPending = false; // 等待手机端决策文件名冲突
  bool _skipUploading = false; // 用户选择跳过：丢弃数据块，结束时回 ack skipped
  // 接收流异步初始化期间（openWrite 未完成）到达的块缓存，避免丢数据
  final List<Uint8List> _pendingChunks = [];
  int _pendingBytes = 0; // 缓存块累计字节数（防内存无限增长）
  bool _finalizePending = false; // file-complete 先于写流就绪到达：待 _beginUpload 就绪后补做完成校验

  // 发送下载状态
  bool _sending = false;

  // ── 初始化 ─────────────────────────────────────────────
  HostController() {
    _service.onRegistered = (code) {
      pairCode = code;
      state = HostState.registered;
      notifyListeners();
    };
    _service.onClientJoined = (info) async {
      clientName = info['clientInfo'] is Map
          ? (info['clientInfo'] as Map)['name']?.toString()
          : null;
      clientName ??= info['name']?.toString();
      // 服务器下发的 TURN 中继凭证（直连失败时的兜底通道）
      final turn = info['turn'];
      _service.turnConfig = turn is Map
          ? Map<String, dynamic>.from(turn)
          : null;
      notifyListeners();
      await _service.createPeerConnectionAndOffer();
    };
    _service.onPeerDisconnected = () {
      if (state == HostState.peerConnected) {
        // 手机端断开：保持等待状态（配对码不变），传输中断留在磁盘的 .part
        // 文件保留，手机端重连后自动续传
        _cleanupBrokenTransfers();
        state = HostState.registered;
        errorMessage = '手机端已断开，电脑端保持等待连接，传输将在重连后自动续传';
        notifyListeners();
      }
    };
    _service.onError = (reason) {
      // 信令服务器暂不可达：保持等待状态并提示，socket 层会自动重连重注册
      if (state == HostState.registered || state == HostState.peerConnected) {
        errorMessage = reason;
        notifyListeners();
      } else {
        errorMessage = reason;
        state = HostState.idle;
        notifyListeners();
      }
    };
    _service.onChannelState = (open) {
      if (open) {
        state = HostState.peerConnected;
        notifyListeners();
      }
    };
    _service.onPairCodeChanged = (code) {
      pairCode = code;
      notifyListeners();
    };
    _service.onData = _onRawData;
  }

  // ── 连接 / 断开 ────────────────────────────────────────
  Future<void> connect({required String server}) async {
    serverUrl = server.replaceAll(RegExp(r'/$'), '');
    state = HostState.idle;
    errorMessage = null;
    notifyListeners();
    await _service.connect(serverUrl);
  }

  Future<void> disconnect() async {
    await _service.dispose();
    state = HostState.idle;
    pairCode = '';
    clientName = null;
    notifyListeners();
  }

  // 传输中断清理：关闭接收流（保留 .part 供续传）、复位发送状态、标记进行中记录为中断
  void _cleanupBrokenTransfers() {
    final sink = _recvSink;
    _recvSink = null;
    if (sink != null) {
      try {
        sink.flush();
        sink.close();
      } catch (_) {}
    }
    _recvFile = null;
    _recvFileName = null;
    _recvRequestId = '';
    _recvExpected = 0;
    _recvBytes = 0;
    _recvSubPath = '';
    _recvStartMs = 0;
    _conflictPending = false;
    _skipUploading = false;
    _finalizePending = false;
    _pendingChunks.clear();
    _pendingBytes = 0;
    _sending = false;
    _currentUploadItem = null;
    for (final t in transfers) {
      if (t.status == 'transferring') t.status = 'error';
    }
  }

  /// 重新生成配对码（旧码立即失效，需重新配对）
  void resetPairCode() {
    _service.resetPairCode();
  }

  // ── 共享目录 ────────────────────────────────────────────
  /// 手动选择共享目录（切换到手动模式）
  Future<void> pickSharedDir() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final dir = Directory(path);
    if (!await dir.exists()) {
      errorMessage = '目录不存在: $path';
      notifyListeners();
      return;
    }
    sharedDir = dir;
    myComputerMode = false;
    localPath = '';
    await refreshLocalFiles();
  }

  /// 恢复默认：共享整台电脑（盘符 + 桌面等特殊目录），无需用户设置
  void restoreMyComputer() {
    myComputerMode = true;
    sharedDir = null;
    localPath = '';
    refreshLocalFiles();
  }

  /// 枚举全部逻辑盘符
  List<String> _listDrives() {
    final drives = <String>[];
    for (var c = 65; c <= 90; c++) {
      final letter = String.fromCharCode(c);
      try {
        if (Directory('$letter:').existsSync()) drives.add('$letter:');
      } catch (_) {}
    }
    return drives;
  }

  /// 「我的电脑」虚拟根：特殊文件夹 + 盘符
  List<FileEntry> _myComputerEntries() {
    final list = <FileEntry>[];
    final profile = Platform.environment['USERPROFILE'] ?? '';
    final specials = <String, String>{
      '桌面': '$profile\\Desktop',
      '文档': '$profile\\Documents',
      '下载': '$profile\\Downloads',
      '图片': '$profile\\Pictures',
      '视频': '$profile\\Videos',
      '音乐': '$profile\\Music',
    };
    for (final e in specials.entries) {
      try {
        if (Directory(e.value).existsSync()) {
          list.add(FileEntry(
            name: e.key,
            type: 'directory',
            path: e.value.replaceAll('\\', '/'),
          ));
        }
      } catch (_) {}
    }
    for (final d in _listDrives()) {
      list.add(FileEntry(name: d, type: 'directory', path: d));
    }
    return list;
  }

  /// 拼接子条目完整路径
  String _childPath(String parent, String name) {
    final base = parent.replaceAll(RegExp(r'/+$'), '');
    return base.isEmpty ? name : '$base/$name';
  }

  Future<void> refreshLocalFiles() async {
    // 「我的电脑」虚拟根
    if (myComputerMode && localPath.isEmpty) {
      localFiles = _myComputerEntries();
      notifyListeners();
      return;
    }
    final dir = _dirAt(localPath);
    if (dir == null) {
      localFiles = [];
      notifyListeners();
      return;
    }
    try {
      final list = <FileEntry>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is Directory) {
          list.add(FileEntry(
              name: e.path.split(Platform.pathSeparator).last,
              type: 'directory',
              path: _childPath(localPath, e.path.split(Platform.pathSeparator).last)));
        } else if (e is File) {
          final s = await e.length();
          final name = e.path.split(Platform.pathSeparator).last;
          list.add(FileEntry(
              name: name,
              type: 'file',
              size: s,
              path: _childPath(localPath, name)));
        }
      }
      list.sort((a, b) => a.type == b.type
          ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
          : a.type == 'directory'
              ? -1
              : 1);
      localFiles = list;
    } catch (e) {
      localFiles = [];
    }
    notifyListeners();
  }

  void openLocalDir(FileEntry entry) {
    localPath = entry.path ??
        (localPath.isEmpty ? entry.name : '$localPath/${entry.name}');
    refreshLocalFiles();
  }

  void navigateLocal(int index) {
    if (index < 0) {
      localPath = '';
    } else {
      final segs =
          localPath.split('/').where((s) => s.isNotEmpty).toList();
      localPath = segs.take(index + 1).join('/');
    }
    refreshLocalFiles();
  }

  /// 路径解析：我的电脑模式/含盘符的路径按绝对路径处理，否则按共享目录相对路径
  Directory? _dirAt(String relPath) {
    if (myComputerMode || relPath.contains(':')) {
      if (relPath.isEmpty) return null; // 虚拟根由 _myComputerEntries 处理
      return Directory(
          relPath.replaceAll('/', Platform.pathSeparator));
    }
    if (sharedDir == null) return null;
    if (relPath.isEmpty) return sharedDir;
    return Directory(
        '${sharedDir!.path}${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
  }

  // ── 数据通道消息处理 ────────────────────────────────────
  void _onRawData(dynamic data) {
    final msg = tryParseControlMessage(data);
    if (msg != null) {
      _onControl(msg);
    } else if (data is List<int>) {
      _onBinary(Uint8List.fromList(data));
    } else if (data is String) {
      // 非 JSON 字符串，忽略
    }
  }

  void _onControl(ControlMessage msg) {
    switch (msg.type) {
      case 'file:list':
        _handleFileList(msg.data['path']?.toString() ?? '',
            msg.data['requestId']?.toString() ?? 'browse');
        break;
      case 'file:download':
        _handleFileDownload(msg.data);
        break;
      case 'file:upload':
        _handleFileUpload(msg.data);
        break;
      case 'file:conflict-resolve':
        _handleConflictResolve(msg.data);
        break;
      case 'file-complete':
        _finalizeUpload();
        break;
      default:
        break;
    }
  }

  // 手机端请求文件列表
  Future<void> _handleFileList(String pathStr, String requestId) async {
    try {
      // 「我的电脑」虚拟根：返回盘符 + 特殊文件夹
      if (myComputerMode && pathStr.isEmpty) {
        _service.sendJson({
          'type': 'file-list-result',
          'files': _myComputerEntries().map((e) => e.toJson()).toList(),
          'requestId': requestId,
        });
        return;
      }
      final dir = _dirAt(pathStr);
      if (dir == null) {
        _service.sendJson({
          'type': 'file-list-result',
          'files': <dynamic>[],
          'error': '电脑端尚未选择共享目录',
          'requestId': requestId,
        });
        return;
      }
      if (!await dir.exists()) {
        _service.sendJson({
          'type': 'file-list-result',
          'files': <dynamic>[],
          'error': '目录不存在',
          'requestId': requestId,
        });
        return;
      }
      final list = <Map<String, dynamic>>[];
      await for (final e in dir.list(followLinks: false)) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (e is Directory) {
          list.add(FileEntry(
                  name: name,
                  type: 'directory',
                  path: _childPath(pathStr, name))
              .toJson());
        } else if (e is File) {
          list.add(FileEntry(
                  name: name,
                  type: 'file',
                  size: await e.length(),
                  path: _childPath(pathStr, name))
              .toJson());
        }
      }
      list.sort((a, b) => a['type'] == b['type']
          ? (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase())
          : a['type'] == 'directory'
              ? -1
              : 1);
      _service.sendJson(
          {'type': 'file-list-result', 'files': list, 'requestId': requestId});
    } catch (e) {
      _service.sendJson({
        'type': 'file-list-result',
        'files': <dynamic>[],
        'error': '读取目录失败: $e',
        'requestId': requestId,
      });
    }
  }

  // 手机端请求下载 → 发送文件（支持断点续传：offset > 0 时从偏移处发送）
  Future<void> _handleFileDownload(Map<String, dynamic> msg) async {
    if (_sending) {
      _service.sendJson({'type': 'file-ack', 'fileName': msg['fileName'], 'success': false});
      return;
    }
    _sending = true;
    try {
      final pathStr = msg['path']?.toString() ?? '';
      // 兼容：绝对路径（我的电脑模式）与相对路径（手动模式/旧版）
      final slash = pathStr.lastIndexOf('/');
      final dirPart = slash > 0 ? pathStr.substring(0, slash) : '';
      final fileName =
          slash >= 0 ? pathStr.substring(slash + 1) : pathStr;
      final dir = _dirAt(dirPart);
      if (dir == null) {
        _service.sendJson(
            {'type': 'file-ack', 'fileName': fileName, 'success': false});
        return;
      }
      final file =
          File('${dir.path}${Platform.pathSeparator}$fileName');
      if (!await file.exists()) {
        _service.sendJson(
            {'type': 'file-ack', 'fileName': fileName, 'success': false});
        return;
      }
      final size = await file.length();
      final offset = msg['offset'] is int ? msg['offset'] as int : 0;
      final start = offset.clamp(0, size); // 手机端断点续传起点（不超文件大小）
      final totalChunks = (size / kChunkSize).ceil();
      _addTransfer(fileName, 'download', size).transferred = start;

      _service.sendJson({
        'type': 'file-meta',
        'fileName': fileName,
        'fileSize': size,
        'totalChunks': totalChunks,
        if (start > 0) 'offset': start,
      });

      final raf = file.openRead(start);
      final startMs = DateTime.now().millisecondsSinceEpoch;
      final t = transfers.lastWhere((x) => x.fileName == fileName && x.status == 'transferring',
          orElse: () => transfers.last);
      await for (final chunk in raf) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        for (var i = 0; i < bytes.length; i += kChunkSize) {
          final end = (i + kChunkSize) < bytes.length ? i + kChunkSize : bytes.length;
          final piece = bytes.sublist(i, end);
          // 背压控制
          while (_service.bufferedAmount > kBackpressureLimit) {
            await Future.delayed(const Duration(milliseconds: 5));
          }
          _service.sendBinary(piece);
          t.transferred += piece.length;
          t.speed = _fmtSpeed(t.transferred - start, startMs);
          notifyListeners();
        }
      }
      _service.sendJson({'type': 'file-complete', 'fileName': fileName, 'fileSize': size});
      t.status = 'done';
      notifyListeners();
    } catch (e) {
      _service.sendJson({'type': 'file-ack', 'fileName': msg['fileName'], 'success': false});
    } finally {
      _sending = false;
    }
  }

  // 手机端上传文件头：先检查重名冲突，无冲突直接开始接收
  Future<void> _handleFileUpload(Map<String, dynamic> msg) async {
    final fileName = msg['fileName']?.toString();
    if (fileName == null || fileName.isEmpty) return;
    // 注意：此处绝不能清除 _finalizePending——上一个文件的 file-complete 可能先于其写流
    // 就绪到达（标记待补做校验），若被新请求清掉，该文件将永远收不到 ack 而卡住
    if (_recvFileName != null || _conflictPending) {
      // 已有传输或冲突等待中，拒绝新请求（正常串行发送下不会触发）
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': msg['requestId']?.toString() ?? '',
        'success': false,
        'reason': 'busy',
      });
      return;
    }
    // 手动模式未选共享目录才拒绝；「我的电脑」模式目录由路径直接解析
    if (sharedDir == null && !myComputerMode) {
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'success': false,
        'reason': 'no-dir',
      });
      return;
    }
    _recvFileName = fileName;
    _recvRequestId = msg['requestId']?.toString() ?? '';
    _recvExpected = msg['fileSize'] is int ? msg['fileSize'] as int : 0;
    _recvSubPath = msg['subPath']?.toString() ?? '';
    _recvBytes = 0;
    _recvStartMs = DateTime.now().millisecondsSinceEpoch;

    try {
      final dir = _dirAt(_recvSubPath);
      if (dir == null) throw Exception('未找到保存目录');
      if (!await dir.exists()) await dir.create(recursive: true);
      final target = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (await target.exists()) {
        // 文件名冲突：通知手机端等待用户决策（期间到达的块由缓存兜底）
        _conflictPending = true;
        _service.sendJson({
          'type': 'file:conflict',
          'fileName': fileName,
          'requestId': _recvRequestId,
        });
        return;
      }
      await _beginUpload();
    } catch (e) {
      _recvFileName = null;
      _pendingChunks.clear();
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': _recvRequestId,
        'success': false,
        'reason': 'no-dir',
      });
    }
  }

  // 初始化接收并告知手机端可以发送数据
  // 断点续传：优先基于磁盘上已有的 .part 实际大小续写（以电脑端为准），
  // accept 回包携带 offset，手机端据此从偏移继续发送
  Future<void> _beginUpload({String? saveAs}) async {
    final fileName = _recvFileName!;
    final saveName = saveAs ?? fileName;
    _conflictPending = false;
    try {
      final dir = _dirAt(_recvSubPath);
      if (dir == null) throw Exception('共享目录未选择');
      if (!await dir.exists()) await dir.create(recursive: true);
      final partFile = File('${dir.path}${Platform.pathSeparator}$saveName.p2p.part');
      // 续传基准：.part 实际大小（磁盘为准）；异常（>= 文件总长）时从头重写
      var baseOffset = 0;
      if (partFile.existsSync()) {
        final len = await partFile.length();
        if (len > 0 && len < _recvExpected) baseOffset = len;
      }
      if (baseOffset == 0 && partFile.existsSync()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      _recvFile = partFile;
      _recvSink = partFile.openWrite(
          mode: baseOffset > 0 ? FileMode.append : FileMode.write);
      _recvBytes = baseOffset;
      _currentUploadItem = _addTransfer(fileName, 'upload', _recvExpected);
      _currentUploadItem!.transferred = baseOffset;
      // 补写初始化期间缓存的块
      if (_pendingChunks.isNotEmpty) {
        for (final c in _pendingChunks) {
          _recvSink!.add(c);
          _recvBytes += c.length;
        }
        _pendingChunks.clear();
        _pendingBytes = 0;
        final t = _currentUploadItem;
        if (t != null && t.direction == 'upload') {
          t.transferred = _recvBytes;
          t.speed = _fmtSpeed(_recvBytes - baseOffset, _recvStartMs);
        }
      }
      _service.sendJson({
        'type': 'file:accept',
        'fileName': fileName,
        'requestId': _recvRequestId,
        // 实际续传起点（0 表示从头接收）；手机端据此定位读取
        if (baseOffset > 0) 'offset': baseOffset,
        if (saveName != fileName) 'saveAs': saveName,
      });
      // 初始化期间 file-complete 已到达：补做完成校验与回包（避免手机端永久等待）
      if (_finalizePending) {
        _finalizePending = false;
        await _finalizeUpload();
      }
    } catch (e) {
      _finalizePending = false;
      _recvFileName = null;
      _pendingChunks.clear();
      _pendingBytes = 0;
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': _recvRequestId,
        'success': false,
        'reason': 'no-dir',
      });
    }
  }

  // 手机端回应文件名冲突决策
  Future<void> _handleConflictResolve(Map<String, dynamic> msg) async {
    final fileName = msg['fileName']?.toString();
    if (fileName == null || fileName != _recvFileName || !_conflictPending) {
      return;
    }
    // 带 requestId 时校验一致性，避免旧决策影响新传输
    final rid = msg['requestId']?.toString();
    if (rid != null && rid.isNotEmpty && rid != _recvRequestId) return;
    final action = msg['action']?.toString() ?? 'skip';
    if (action == 'skip') {
      _conflictPending = false;
      _skipUploading = true; // 丢弃数据块，file-complete 时回 ack skipped
      return;
    }
    if (action == 'rename') {
      final saveAs = _autoRename(fileName);
      await _beginUpload(saveAs: saveAs);
    } else {
      await _beginUpload(); // overwrite
    }
  }

  // 自动生成不冲突的文件名：name (1).ext、name (2).ext ...
  String _autoRename(String fileName) {
    final dir = _dirAt(_recvSubPath);
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; ; i++) {
      final candidate = '$base ($i)$ext';
      final f = File('${dir!.path}${Platform.pathSeparator}$candidate');
      if (!f.existsSync()) return candidate;
    }
  }

  // 二进制块（上传数据）
  void _onBinary(Uint8List bytes) {
    final sink = _recvSink;
    if (sink == null) {
      // 用户选择跳过：直接丢弃，不缓存
      if (_skipUploading) return;
      // 接收初始化中（异步打开写流）：缓存块，就绪后补写，避免丢块
      if (_recvFileName != null && _recvExpected > 0) {
        _pendingChunks.add(bytes);
        _pendingBytes += bytes.length;
        if (_pendingBytes > kPendingChunkLimit) {
          // 写流长时间未就绪（异常）：放弃本次接收，避免内存无限增长
          final fname = _recvFileName;
          final rid = _recvRequestId;
          _recvFileName = null;
          _recvExpected = 0;
          _pendingChunks.clear();
          _pendingBytes = 0;
          _conflictPending = false;
          _finalizePending = false; // 本次接收已放弃，不再补做校验
          _service.sendJson({
            'type': 'file-ack',
            'fileName': fname,
            'requestId': rid,
            'success': false,
            'reason': 'no-recv',
          });
          notifyListeners();
        }
      }
      return;
    }
    if (_skipUploading) return;
    sink.add(bytes);
    _recvBytes += bytes.length;
    final t = _currentUploadItem ??
        (transfers.isNotEmpty ? transfers.last : null);
    if (t != null && t.status == 'transferring' && t.direction == 'upload') {
      t.transferred = _recvBytes;
      t.speed = _fmtSpeed(_recvBytes, _recvStartMs);
      notifyListeners();
    }
  }

  // 上传完成
  Future<void> _finalizeUpload() async {
    // 快照接收状态：本函数在 flush/close 处异步挂起期间，
    // 下一个文件的 file:upload 会重置这些全局状态，必须用快照完成校验与回包
    final fileName = _recvFileName;
    final requestId = _recvRequestId;
    final recvBytes = _recvBytes;
    final recvExpected = _recvExpected;
    final subPath = _recvSubPath;
    final item = _currentUploadItem;
    final sink = _recvSink;
    if (sink == null) {
      // 写流尚未就绪（_beginUpload 初始化挂起中）：
      // 标记待完成，由 _beginUpload 就绪后补做校验与回包
      if (_recvFileName != null && recvExpected > 0) {
        _finalizePending = true;
        return;
      }
      // 完全无接收状态（块被丢弃/消息错乱）：回失败，避免手机端永久等待
      _pendingBytes = 0;
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': false,
        'reason': 'no-recv',
      });
      notifyListeners();
      return;
    }
    _recvSink = null;
    _recvFileName = null;
    _currentUploadItem = null;
    _pendingChunks.clear();
    _pendingBytes = 0;
    _conflictPending = false;
    if (_skipUploading) {
      // 用户选择跳过：无文件落地，告知手机端
      _skipUploading = false;
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': false,
        'reason': 'skipped',
      });
      notifyListeners();
      return;
    }
    try {
      await sink.flush();
      await sink.close();
      final ok = recvBytes == recvExpected;
      final saveName = fileName; // 正常接收时保存名即文件名
      if (item != null) {
        item.status = ok ? 'done' : 'error';
      }
      // 成功：.part 重命名为正式文件名；失败：删除残留 part
      final part = _recvFile;
      if (ok && part != null) {
        try {
          final dir = _dirAt(subPath);
          var finalName = saveName ?? '';
          if (dir != null) {
            final target = File('${dir.path}${Platform.pathSeparator}$finalName');
            if (await target.exists()) {
              // 极端情况：传输期间正式名已存在（外部创建），自动改名
              finalName = _autoRename(finalName);
            }
            await part.rename('${dir.path}${Platform.pathSeparator}$finalName');
          }
        } catch (_) {
          // 重命名失败不阻塞回包
        }
      } else if (!ok && part != null) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': ok,
        if (!ok) 'reason': 'size-mismatch',
      });
      if (ok && sharedDir != null && subPath.isEmpty) refreshLocalFiles();
    } catch (e) {
      _service.sendJson({
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': false,
      });
    }
    notifyListeners();
  }

  // ── 辅助 ────────────────────────────────────────────────
  TransferItem _addTransfer(String name, String direction, int total) {
    final t = TransferItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: name,
      direction: direction,
      total: total,
      startTime: DateTime.now(),
    );
    transfers.add(t);
    notifyListeners();
    return t;
  }

  String _fmtSpeed(int bytes, int startMs) {
    final elapsed = (DateTime.now().millisecondsSinceEpoch - startMs) / 1000;
    if (elapsed <= 0) return '';
    final mbps = bytes / 1048576 / elapsed;
    return '${mbps.toStringAsFixed(2)} MB/s';
  }

  @override
  void dispose() {
    _pendingChunks.clear();
    _pendingBytes = 0;
    _conflictPending = false;
    _skipUploading = false;
    _service.dispose();
    super.dispose();
  }
}
