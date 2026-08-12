import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'app_log.dart';
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

/// 共享配置：管理员给某个用户（设备或手机号）共享的一个文件夹
class ShareConfig {
  final String token; // 共享码（二维码内容的一部分）
  final String folder; // 共享文件夹绝对路径（/ 分隔）
  final List<String> perms; // ['download','upload','delete']
  String? targetDeviceId; // 目标用户设备 id（null=未绑定/公开）
  final String? targetPhone; // 目标用户手机号（null=未指定/公开）

  ShareConfig({
    required this.token,
    required this.folder,
    required this.perms,
    this.targetDeviceId,
    this.targetPhone,
  });

  String get name => folder.split('/').last;

  bool get canDownload => perms.contains('download');
  bool get canUpload => perms.contains('upload');
  bool get canDelete => perms.contains('delete');

  /// 公开共享（二维码）：未指定目标设备与手机号
  bool get isPublic => targetDeviceId == null && targetPhone == null;

  Map<String, dynamic> toJson() => {
        'token': token,
        'folder': folder,
        'perms': perms,
        if (targetDeviceId != null) 'targetDeviceId': targetDeviceId,
        if (targetPhone != null) 'targetPhone': targetPhone,
      };

  factory ShareConfig.fromJson(Map<String, dynamic> json) => ShareConfig(
        token: json['token']?.toString() ?? '',
        folder: json['folder']?.toString() ?? '',
        perms: (json['perms'] as List? ?? [])
            .map((e) => e.toString())
            .toList(),
        targetDeviceId: json['targetDeviceId']?.toString(),
        targetPhone: json['targetPhone']?.toString(),
      );
}

/// 手机端用户（多用户管理）
class HostUser {
  String deviceId;
  String name;
  String? clientId; // 当前 socket 会话 id（在线时非空）
  String phone = ''; // 登录手机号（join 时上报）
  bool isAdmin;
  bool shareOnly = false; // 共享访客（扫码共享加入）：永不成为管理员
  final List<ShareConfig> shares = [];
  final DateTime joinedAt;

  HostUser({
    required this.deviceId,
    required this.name,
    this.clientId,
    this.isAdmin = false,
    DateTime? joinedAt,
  }) : joinedAt = joinedAt ?? DateTime.now();

  bool get online => clientId != null;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'phone': phone,
        'isAdmin': isAdmin,
        'shareOnly': shareOnly,
        'online': online,
        'joinedAt': joinedAt.millisecondsSinceEpoch,
        'shares': shares.map((s) => s.toJson()).toList(),
      };

  factory HostUser.fromJson(Map<String, dynamic> json) => HostUser(
        deviceId: json['deviceId']?.toString() ?? '',
        name: json['name']?.toString() ?? '手机',
        clientId: json['clientId']?.toString(),
        isAdmin: json['isAdmin'] == true,
        joinedAt:
            DateTime.fromMillisecondsSinceEpoch(json['joinedAt'] is int ? json['joinedAt'] as int : 0),
      )
        ..phone = json['phone']?.toString() ?? ''
        ..shareOnly = json['shareOnly'] == true
        ..shares.addAll((json['shares'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ShareConfig.fromJson(Map<String, dynamic>.from(e))));
}

/// 单个客户端的接收（上传）状态：多用户各自独立，互不串扰
class _RecvState {
  File? file; // .part 文件
  IOSink? sink;
  TransferItem? currentUploadItem;
  int expected = 0;
  int bytes = 0;
  int startMs = 0;
  int lastLogBytes = 0;
  String? fileName;
  String? requestId;
  String? subPath; // 保存子路径
  bool conflictPending = false; // 等待手机端决策文件名冲突
  bool skipUploading = false; // 用户选择跳过：丢弃数据块，结束时回 ack skipped
  bool finalizePending = false; // file-complete 先于写流就绪到达
  DateTime? lastChunkAt; // 最近一次收到数据块的时间（接收超时兜底）
  ShareConfig? share; // 非空=保存到共享目录（相对路径）
  final List<Uint8List> pendingChunks = []; // 写流初始化期间到达的块缓存
  int pendingBytes = 0;
  int overflowBytes = 0; // 超量到达的数据（手机端起点错位/重复发送），不计入 bytes
}

/// 电脑端控制器：编排信令、WebRTC、共享目录与文件传输（多用户）
class HostController extends ChangeNotifier {
  final HostService _service = HostService();

  /// 接收超时检测：手机端异常（发送中断但通道未断）时，长时间无数据块则判定失败
  static const Duration _recvTimeout = Duration(minutes: 5);
  Timer? _recvTimeoutTimer;

  HostState state = HostState.idle;
  String pairCode = '';
  String? errorMessage;
  String serverUrl = 'http://127.0.0.1:3000';

  // ── 共享目录 ────────────────────────────────────────────
  Directory? sharedDir; // 手动模式下的共享根目录
  bool myComputerMode = true; // 默认共享「我的电脑」（全部磁盘 + 桌面等）
  List<FileEntry> localFiles = [];
  String localPath = ''; // 我的电脑模式为绝对路径，手动模式为相对共享目录路径

  // ── 多用户管理 ──────────────────────────────────────────
  final Map<String, HostUser> users = {}; // deviceId -> 用户
  final Map<String, ShareConfig> _shareTable = {}; // token -> 共享配置（全局）
  String? adminDeviceId; // 第一个连接的手机端为管理员
  String? adminPhone; // 管理员手机号（同一手机号的任何设备都视为管理员）

  // ── 传输记录 ────────────────────────────────────────────
  final List<TransferItem> transfers = [];

  // 多客户端传输状态（按 clientId 隔离）
  final Map<String, _RecvState> _recvStates = {};
  final Set<String> _sendingClients = {}; // 正在发送下载的客户端
  int _sentLogBytes = 0; // 发送进度日志基准（诊断用）

  /// 在线手机端数量
  int get onlineCount => users.values.where((u) => u.online).length;

  /// 全部共享配置（共享文件夹管理页展示：公开/手机号/设备绑定）
  List<ShareConfig> get shareList => _shareTable.values.toList();

  /// 当前连接方式标签（取第一个在线用户，用于电脑端 UI 展示）
  String get connTypeLabel {
    for (final s in _service.sessions.values) {
      if (s.isOpen) {
        return switch (s.connectionType) {
          'relay' => '服务器中转',
          'direct' => 'P2P直连',
          _ => '探测中…',
        };
      }
    }
    return '未连接';
  }

  // ── 初始化 ─────────────────────────────────────────────
  HostController() {
    // 每 30 秒扫描一次活跃接收：无进展超时后置错并回包，避免永久卡「正在发送」
    _recvTimeoutTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _checkRecvTimeouts());
    _service.onRegistered = (code) {
      pairCode = code;
      state = HostState.registered;
      AppLog.i('host', '注册成功: 配对码=$code');
      notifyListeners();
    };
    _service.onClientJoined = (info) async {
      final clientInfo = info['clientInfo'];
      final cInfo = clientInfo is Map
          ? Map<String, dynamic>.from(clientInfo)
          : <String, dynamic>{};
      final clientId = cInfo['id']?.toString() ?? '';
      final deviceId = cInfo['deviceId']?.toString() ?? clientId;
      final name = cInfo['name']?.toString() ?? '手机';
      final phone = cInfo['phone']?.toString();
      final shareToken = cInfo['shareToken']?.toString();
      final turn = info['turn'];
      _service.turnConfig = turn is Map
          ? Map<String, dynamic>.from(turn)
          : null;
      AppLog.i('host', '手机端加入: $name (deviceId=$deviceId phone=$phone share=$shareToken)');
      _ensureUser(
          deviceId: deviceId,
          name: name,
          clientId: clientId,
          phone: phone,
          shareToken: shareToken);
      notifyListeners();
      await _service.createPeerConnectionAndOffer(clientId,
          deviceId: deviceId, clientName: name, shareToken: shareToken);
    };
    _service.onPeerDisconnected = (clientId, deviceId) {
      AppLog.i('host', '手机端断开: clientId=$clientId deviceId=$deviceId (state=$state)');
      if (state == HostState.peerConnected || state == HostState.registered) {
        // 手机端断开：清理该客户端的传输状态（保留 .part 供续传）
        unawaited(_cleanupBrokenTransfers(clientId));
        _recvStates.remove(clientId);
        _sendingClients.remove(clientId);
        for (final u in users.values) {
          if (u.clientId == clientId) {
            u.clientId = null;
            AppLog.i('host', '用户离线: ${u.name} (${u.deviceId})');
          }
        }
        // 关闭残留会话：通道关闭后 session 仍留在 _sessions，
        // 后续发送会静默失败、发送循环也感知不到（曾导致"发送完成"假象）
        unawaited(_service.removeSession(clientId));
        state = onlineCount > 0 ? HostState.peerConnected : HostState.registered;
        errorMessage = null;
        notifyListeners();
      }
    };
    _service.onKicked = (reason) {
      AppLog.e('host', '被服务器移出: $reason');
      if (state == HostState.registered || state == HostState.peerConnected) {
        errorMessage = reason;
        notifyListeners();
      }
    };
    _service.onError = (reason) {
      AppLog.e('host', '服务错误: $reason');
      if (state == HostState.registered || state == HostState.peerConnected) {
        errorMessage = reason;
        notifyListeners();
      } else {
        errorMessage = reason;
        state = HostState.idle;
        notifyListeners();
      }
    };
    _service.onChannelState = (clientId, open) {
      if (open) {
        state = HostState.peerConnected;
      } else if (_service.sessions.values.every((s) => !s.isOpen)) {
        state = onlineCount > 0 ? state : HostState.registered;
      }
      notifyListeners();
    };
    // 连接方式探测完成：刷新 UI（直连/服务器中转徽标）
    _service.onConnectionType = (_, _) => notifyListeners();
    _service.onPairCodeChanged = (code) {
      pairCode = code;
      notifyListeners();
    };
    _service.onData = _onRawData;
  }

  // ── 用户管理 ────────────────────────────────────────────
  /// 校验共享目标是否匹配该用户（设备 id 或手机号；均未指定=公开）
  bool _canBind(ShareConfig share, String deviceId, String phone) {
    if (share.targetDeviceId != null && share.targetDeviceId != deviceId) {
      return false;
    }
    if (share.targetPhone != null && share.targetPhone != phone) {
      return false;
    }
    return true;
  }

  /// 手机端加入时确保用户存在；
  /// 管理员从配对连接中产生：首个配对手机端（且无持久化管理员手机号）
  /// 成为管理员；共享访客（扫码共享加入）永不成为管理员；
  /// 共享码用户绑定共享；手机号指定共享自动绑定
  void _ensureUser({
    required String deviceId,
    required String name,
    String? clientId,
    String? phone,
    String? shareToken,
  }) {
    var user = users[deviceId];
    final shareOnly = shareToken != null && shareToken.isNotEmpty;
    if (user == null) {
      // 共享访客不算「首个连接」；管理员只从配对连接中产生，
      // 且已恢复持久化管理员手机号时不自动指定（由手机号识别恢复身份）
      final first = !shareOnly &&
          (users.isEmpty || users.values.every((u) => u.shareOnly)) &&
          (adminPhone == null || adminPhone!.isEmpty);
      user = HostUser(deviceId: deviceId, name: name, clientId: clientId);
      if (phone != null && phone.isNotEmpty) user.phone = phone;
      user.shareOnly = shareOnly;
      if (first) {
        user.isAdmin = true;
        adminDeviceId = deviceId;
        if (phone != null && phone.isNotEmpty) {
          adminPhone = phone;
          unawaited(_saveAdminPhone(phone));
        }
        AppLog.i('host', '首个配对手机端成为管理员: $name ($deviceId) phone=$phone');
      } else {
        // 普通用户：校验共享码（共享目标需匹配该设备/手机号或公开共享）
        final share = shareToken != null ? _shareTable[shareToken] : null;
        if (share != null && _canBind(share, deviceId, user.phone)) {
          if (!user.shares.any((s) => s.token == share.token)) {
            user.shares.add(share);
          }
          AppLog.i('host', '共享码用户绑定共享: ${share.name}');
        }
      }
      _bindPhoneShares(user);
      users[deviceId] = user;
      notifyListeners();
    } else {
      user.name = name;
      user.clientId = clientId;
      if (phone != null && phone.isNotEmpty && user.phone.isEmpty) {
        user.phone = phone;
      }
      // 共享访客之后用配对码连接：升级为正式用户
      if (!shareOnly && user.shareOnly) {
        user.shareOnly = false;
        // 升级时补选管理员：若此前没有其他正式用户（首个配对连接者）
        // 且无持久化管理员手机号，则本次配对连接者成为管理员，
        // 避免“先扫码访客后配对”导致永远选不出管理员
        if (adminPhone == null || adminPhone!.isEmpty) {
          final others = users.values
              .where((u) => u.deviceId != deviceId && !u.shareOnly);
          if (others.isEmpty) {
            user.isAdmin = true;
            adminDeviceId = deviceId;
            if (user.phone.isNotEmpty) {
              adminPhone = user.phone;
              unawaited(_saveAdminPhone(user.phone));
            }
            AppLog.i('host',
                '升级用户补选为管理员（首个配对连接）: $name ($deviceId)');
          }
        }
        AppLog.i('host', '共享访客升级为正式用户: $name ($deviceId)');
      }
      _bindPhoneShares(user);
    }
  }

  // ── 管理员手机号持久化（电脑端重启后恢复管理员身份） ───────
  Future<File> _adminFile() async {
    final docs = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$docs\\Documents\\p2p_desktop_logs');
    await dir.create(recursive: true);
    return File('${dir.path}\\admin.json');
  }

  /// 启动/重新连接时恢复持久化的管理员手机号
  Future<void> _loadAdminPhone() async {
    try {
      final f = await _adminFile();
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString());
      final phone = (json is Map && json['adminPhone'] is String &&
              (json['adminPhone'] as String).isNotEmpty)
          ? json['adminPhone'] as String
          : null;
      if (phone != null && adminPhone != phone) {
        adminPhone = phone;
        AppLog.i('host', '从本地文件恢复管理员手机号: $phone');
      }
    } catch (e) {
      AppLog.w('host', '读取管理员文件失败', e);
    }
  }

  Future<void> _saveAdminPhone(String? phone) async {
    if (phone == null || phone.isEmpty) return;
    try {
      final f = await _adminFile();
      await f.writeAsString(jsonEncode({'adminPhone': phone}));
      AppLog.i('host', '管理员手机号已保存: $phone');
    } catch (e) {
      AppLog.w('host', '保存管理员文件失败', e);
    }
  }

  /// 手机号指定共享：该手机号用户（首次出现或重连）自动绑定对应共享
  void _bindPhoneShares(HostUser user) {
    if (user.phone.isEmpty) return;
    var changed = false;
    for (final s in _shareTable.values) {
      if (s.targetPhone != null &&
          s.targetPhone == user.phone &&
          s.targetDeviceId == null) {
        s.targetDeviceId = user.deviceId;
        if (!user.shares.any((x) => x.token == s.token)) {
          user.shares.add(s);
          changed = true;
        }
        AppLog.i('host', '手机号共享自动绑定: ${s.name} → ${user.name}');
      }
    }
    if (changed) {
      // 通知对方立即刷新（离线转在线自动绑定时共享立即可见）
      if (user.clientId != null) {
        _sendTo(user.clientId!, {'type': 'user:share-updated'});
      }
      notifyListeners();
    }
  }

  HostUser? _userByClientId(String clientId) {
    for (final u in users.values) {
      if (u.clientId == clientId) return u;
    }
    return null;
  }

  /// 校验客户端对共享 token 的访问权
  ShareConfig? _checkShare(String clientId, String token) {
    final user = _userByClientId(clientId);
    if (user == null) return null;
    for (final s in user.shares) {
      if (s.token == token) return s;
    }
    return null;
  }

  /// 管理员踢出用户（仅断开，保留记录可重新扫码加入）
  void kickUser(String deviceId) {
    final user = users[deviceId];
    if (user == null || user.isAdmin || user.clientId == null) return;
    _service.kickClient(user.clientId!);
    user.clientId = null;
    notifyListeners();
  }

  /// 管理员删除用户（断开 + 移除记录与共享）
  void removeUser(String deviceId) {
    final user = users[deviceId];
    if (user == null || user.isAdmin) return;
    if (user.clientId != null) {
      _service.kickClient(user.clientId!);
    }
    for (final s in user.shares) {
      _shareTable.remove(s.token);
    }
    users.remove(deviceId);
    notifyListeners();
  }

  /// 管理员共享文件夹：按设备 id / 手机号 / 公开（二维码）三种方式
  /// - deviceId 指定：直接共享给该设备用户
  /// - phone 指定：匹配在线用户则直接绑定；否则待该手机号加入时自动绑定
  /// - 两者皆空：公开共享（扫码即可加入）
  ShareConfig? createShare({
    String? deviceId,
    String? phone,
    required String folder,
    required List<String> perms,
  }) {
    // 路径必须是绝对路径且存在
    final dir = Directory(folder.replaceAll('/', Platform.pathSeparator));
    if (!dir.existsSync()) return null;

    // 手机号指定：匹配已登记用户；未匹配则创建待绑定共享
    if (phone != null && phone.isNotEmpty) {
      HostUser? target;
      for (final u in users.values) {
        if (u.phone == phone) {
          target = u;
          break;
        }
      }
      if (target != null) deviceId = target.deviceId;
      // 不重复共享：已绑定用户按用户查，待绑定按手机号查
      if (deviceId != null && deviceId.isNotEmpty) {
        for (final s in users[deviceId]!.shares) {
          if (s.folder == folder) return s;
        }
      } else {
        for (final s in _shareTable.values) {
          if (s.targetPhone == phone && s.folder == folder) return s;
        }
      }
      final share = ShareConfig(
        token: _genToken(),
        folder: folder,
        perms: perms,
        targetDeviceId: deviceId != null && deviceId.isNotEmpty ? deviceId : null,
        targetPhone: phone,
      );
      if (deviceId != null && deviceId.isNotEmpty) {
        final bound = users[deviceId]!;
        bound.shares.add(share);
        // 通知对方立即刷新（手机号方式：对方直接就能看到共享内容）
        if (bound.clientId != null) {
          _sendTo(bound.clientId!, {'type': 'user:share-updated'});
        }
      }
      _shareTable[share.token] = share;
      AppLog.i('host', '创建共享(手机号): $phone -> $folder token=${share.token} '
          'perms=$perms ${deviceId != null ? '已绑定' : '待绑定'}');
      notifyListeners();
      return share;
    }

    // 设备指定（原逻辑）或公开共享
    final user = deviceId != null && deviceId.isNotEmpty ? users[deviceId] : null;
    if (user == null && (deviceId != null && deviceId.isNotEmpty)) return null;
    if (user != null) {
      // 同一用户同一文件夹不重复共享
      for (final s in user.shares) {
        if (s.folder == folder) return s;
      }
    }
    final share = ShareConfig(
        token: _genToken(),
        folder: folder,
        perms: perms,
        targetDeviceId: deviceId);
    user?.shares.add(share);
    _shareTable[share.token] = share;
    AppLog.i('host', '创建共享: ${user?.name ?? '公开二维码'} -> $folder '
        'token=${share.token} perms=$perms');
    notifyListeners();
    return share;
  }

  /// 管理员取消共享（从所有用户移除）
  void removeShare(String token) {
    final share = _shareTable.remove(token);
    if (share == null) return;
    for (final u in users.values) {
      u.shares.removeWhere((s) => s.token == token);
    }
    AppLog.i('host', '取消共享: ${share.name} token=$token');
    notifyListeners();
  }

  /// 管理员修改共享权限，并通知已绑定的用户即时刷新
  void updateSharePerms(String token, List<String> perms) {
    final share = _shareTable[token];
    if (share == null) return;
    final clean = perms
        .where((e) => ['download', 'upload', 'delete'].contains(e))
        .toList();
    share.perms
      ..clear()
      ..addAll(clean);
    for (final u in users.values) {
      if (u.shares.any((s) => s.token == token) && u.clientId != null) {
        _sendTo(u.clientId!, {'type': 'user:share-updated'});
      }
    }
    AppLog.i('host', '修改共享权限: ${share.name} perms=$clean');
    notifyListeners();
  }

  /// 已连接用户扫码附加共享（管理员扫自己的码/用户扫新码）
  bool attachShare(String clientId, String token) {
    final user = _userByClientId(clientId);
    final share = _shareTable[token];
    if (user == null || share == null) return false;
    if (!user.shares.any((s) => s.token == token)) {
      // 校验共享目标：共享给该用户（设备/手机号）或公开
      if (!_canBind(share, user.deviceId, user.phone)) {
        return false;
      }
      user.shares.add(share);
      notifyListeners();
    }
    return true;
  }

  String _genToken() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random();
    var s = '';
    for (var i = 0; i < 8; i++) {
      s += chars[r.nextInt(chars.length)];
    }
    return s;
  }

  // ── 连接 / 断开 ────────────────────────────────────────
  Future<void> connect({required String server}) async {
    serverUrl = server.replaceAll(RegExp(r'/$'), '');
    AppLog.i('host', '连接信令服务器: $serverUrl');
    state = HostState.idle;
    errorMessage = null;
    notifyListeners();
    // 重新连接时恢复持久化的管理员手机号（进程内断开重连场景）
    await _loadAdminPhone();
    await _service.connect(serverUrl);
  }

  Future<void> disconnect() async {
    await _service.dispose();
    state = HostState.idle;
    pairCode = '';
    users.clear();
    adminDeviceId = null;
    adminPhone = null;
    _shareTable.clear();
    _recvStates.clear();
    _sendingClients.clear();
    notifyListeners();
  }

  // 传输中断清理：关闭该客户端的接收流（保留 .part 供续传）、复位发送状态
  Future<void> _cleanupBrokenTransfers(String clientId) async {
    AppLog.i('host', '清理中断传输（保留.part供续传）[$clientId]');
    // 断开/超时：该客户端的进行中传输记录标记失败，避免界面永久显示「正在发送」
    for (final t in transfers) {
      if (t.clientId == clientId && t.status == 'transferring') {
        t.status = 'error';
      }
    }
    final rs = _recvStates[clientId];
    if (rs == null) {
      notifyListeners();
      return;
    }
    final sink = rs.sink;
    rs.sink = null;
    if (sink != null) {
      // 必须等待 flush/close 完成：否则缓冲数据丢失且文件句柄泄漏
      // （Windows 下泄漏句柄会锁死 .part，后续续传/重写全部失败）
      try {
        await sink.flush();
        await sink.close();
        AppLog.i('host', '中断传输写流已关闭（缓冲数据已落盘）[$clientId]');
      } catch (e) {
        AppLog.e('host', '关闭中断传输写流失败（缓冲数据可能丢失）[$clientId]', e);
      }
    }
    rs.file = null;
    rs.fileName = null;
    rs.requestId = null;
    rs.expected = 0;
    rs.bytes = 0;
    rs.subPath = null;
    rs.startMs = 0;
    rs.conflictPending = false;
    rs.skipUploading = false;
    rs.finalizePending = false;
    rs.pendingChunks.clear();
    rs.pendingBytes = 0;
    rs.overflowBytes = 0;
    rs.share = null;
    _sendingClients.remove(clientId);
    rs.currentUploadItem = null;
    rs.lastChunkAt = null;
    notifyListeners();
  }

  // 接收超时兜底：手机端发送中断但通道未断开（如应用被杀/异常）时，
  // 长时间无数据块则判定本次接收失败：回 ack、置错记录、清理接收状态
  void _checkRecvTimeouts() {
    final now = DateTime.now();
    for (final e in _recvStates.entries.toList()) {
      final rs = e.value;
      // 仅检查进行中的真实接收（等待冲突决策/完成补做的不算）
      if (rs.fileName == null || rs.expected <= 0) continue;
      if (rs.finalizePending || rs.conflictPending) continue;
      final last = rs.lastChunkAt;
      if (last == null) continue;
      if (now.difference(last) > _recvTimeout) {
        final fname = rs.fileName;
        final rid = rs.requestId;
        AppLog.e('upload',
            '接收超时($_recvTimeout 无数据块)，判定失败: $fname [$e.key]');
        _sendTo(e.key, {
          'type': 'file-ack',
          'fileName': fname,
          'requestId': rid,
          'success': false,
          'reason': 'timeout',
        });
        unawaited(_cleanupBrokenTransfers(e.key)); // 置错记录并清理接收状态（保留 .part）
      }
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

  /// 共享目录路径解析：相对共享文件夹，防路径穿越（必须位于共享文件夹内）
  Directory? _dirAtShared(ShareConfig share, String relPath) {
    final base = share.folder.replaceAll('/', Platform.pathSeparator);
    final baseDir = Directory(base);
    if (!baseDir.existsSync()) return null;
    if (relPath.isEmpty) return baseDir;
    // 规范化 + 穿越防护
    final target = Directory(
        '$base${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}');
    final baseNorm = baseDir.absolute.path;
    final targetNorm = target.absolute.path;
    if (!targetNorm.startsWith(baseNorm + Platform.pathSeparator) &&
        targetNorm != baseNorm) {
      return null;
    }
    return target;
  }

  // ── 数据通道消息处理（多客户端路由） ─────────────────────
  void _onRawData(String clientId, dynamic data) {
    final msg = tryParseControlMessage(data);
    if (msg != null) {
      _onControl(clientId, msg);
    } else if (data is List<int>) {
      _onBinary(clientId, Uint8List.fromList(data));
    } else if (data is String) {
      // 非 JSON 字符串，忽略
    }
  }

  void _onControl(String clientId, ControlMessage msg) {
    switch (msg.type) {
      case 'file:list':
        _handleFileList(clientId, msg.data['path']?.toString() ?? '',
            msg.data['requestId']?.toString() ?? 'browse',
            share: msg.data['share']?.toString());
        break;
      case 'file:download':
        _handleFileDownload(clientId, msg.data);
        break;
      case 'file:upload':
        _handleFileUpload(clientId, msg.data);
        break;
      case 'file:conflict-resolve':
        _handleConflictResolve(clientId, msg.data);
        break;
      case 'file-complete':
        _finalizeUpload(clientId);
        break;
      case 'recv-stats':
        // 自适应流控：手机端消费进度+写盘缓冲反馈（差分算消费速率 → 动态限速）
        final written =
            msg.data['written'] is int ? msg.data['written'] as int : 0;
        final buffered =
            msg.data['buffered'] is int ? msg.data['buffered'] as int : 0;
        _service.sessions[clientId]?.onConsumeStats(written, buffered);
        break;
      case 'recv-error':
        // 手机端接收失败（典型：存储空间不足）：中止发送，
        // 避免电脑端继续发完报"完成"而手机端卡在"正在下载"
        final abSession = _service.sessions[clientId];
        if (abSession != null) {
          abSession.abortRequested = true;
          AppLog.w('download',
              '手机端接收失败(${msg.data['reason']}) ${msg.data['fileName']} → 中止发送 [$clientId]');
        }
        break;
      case 'file:delete':
        _handleFileDelete(clientId, msg.data);
        break;
      case 'user:list':
        _handleUserList(clientId);
        break;
      case 'user:create-share':
        _handleCreateShare(clientId, msg.data);
        break;
      case 'user:remove-share':
        _handleRemoveShare(clientId, msg.data);
        break;
      case 'user:update-share':
        _handleUpdateSharePerms(clientId, msg.data);
        break;
      case 'user:kick':
        _handleUserKick(clientId, msg.data);
        break;
      case 'user:remove':
        _handleUserRemove(clientId, msg.data);
        break;
      case 'user:attach-share':
        _handleAttachShare(clientId, msg.data);
        break;
      case 'user:claim-admin':
        _handleClaimAdmin(clientId);
        break;
      default:
        break;
    }
  }

  bool _isAdmin(String clientId) {
    final user = _userByClientId(clientId);
    if (user == null) return false;
    if (user.isAdmin) return true;
    // 管理员手机号识别：同一手机号登录的任何设备都视为管理员
    // （换手机/重装应用导致 deviceId 变化后仍保有管理员身份）
    if (adminPhone != null && adminPhone!.isNotEmpty && user.phone == adminPhone) {
      user.isAdmin = true;
      adminDeviceId ??= user.deviceId;
      AppLog.i('host', '管理员手机号识别: ${user.name} (${user.phone})');
      _pushUserList(clientId);
      return true;
    }
    // 管理员身份兜底：若当前没有任何管理员在线（如管理员设备重装/更换后
    // deviceId 变化），则首个在线的用户自动成为管理员，避免管理功能失联
    final online = users.values.where((u) => u.online).toList()
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    if (online.isNotEmpty && online.first.clientId == clientId) {
      user.isAdmin = true;
      adminDeviceId ??= user.deviceId;
      if (user.phone.isNotEmpty) adminPhone ??= user.phone;
      AppLog.i('host', '无管理员在线，自动升级为首个在线用户: ${user.name}');
      _pushUserList(clientId);
      return true;
    }
    return false;
  }

  /// 向指定客户端推送完整用户列表（含全量共享），用于身份/状态即时同步
  void _pushUserList(String clientId) {
    final user = _userByClientId(clientId);
    if (user == null) return;
    final admin = _isAdminRaw(user);
    _sendTo(clientId, {
      'type': 'user:list-result',
      // 非管理员（含共享访客）只返回自己条目，避免暴露其他用户信息
      'users': admin
          ? users.values.map((u) => u.toJson()).toList()
          : [user.toJson()],
      'myDeviceId': user.deviceId,
      'isAdmin': admin,
      if (admin)
        'shares': _shareTable.values.map((s) => s.toJson()).toList(),
    });
  }

  /// 纯判定：不做任何身份升级/推送（供 _pushUserList 使用，避免递归）
  bool _isAdminRaw(HostUser user) =>
      user.isAdmin ||
      (adminPhone != null &&
          adminPhone!.isNotEmpty &&
          user.phone == adminPhone);

  Future<void> _sendTo(String clientId, Map<String, dynamic> json) async {
    await _service.sendJsonTo(clientId, json);
  }

  // ── 用户管理消息 ────────────────────────────────────────
  void _handleUserList(String clientId) {
    final admin = _isAdmin(clientId);
    final me = _userByClientId(clientId);
    // 已有其他管理员（按手机号识别）且当前为配对用户：告知手机端现任管理员
    // 手机号，便于提示“是否更换管理员”（共享访客无权更换）
    String? occupiedBy;
    if (!admin &&
        adminPhone != null &&
        adminPhone!.isNotEmpty &&
        me != null &&
        !me.shareOnly &&
        me.phone.isNotEmpty &&
        me.phone != adminPhone) {
      final owner = users.values
          .where((u) => u.phone == adminPhone && !u.shareOnly)
          .toList();
      occupiedBy = owner.isNotEmpty ? owner.first.phone : adminPhone;
      AppLog.i('host',
          '已有管理员 ${me.name}: 现任=$occupiedBy 请求者=${me.phone} → 提示更换');
    }
    _sendTo(clientId, {
      'type': 'user:list-result',
      // 非管理员（含共享访客）只返回自己条目，避免暴露其他用户信息
      'users': admin
          ? users.values.map((u) => u.toJson()).toList()
          : (me != null ? [me.toJson()] : <dynamic>[]),
      'myDeviceId': me?.deviceId ?? '',
      'isAdmin': admin,
      'adminPhone': ?occupiedBy,
      // 管理员额外返回全部共享配置（共享文件夹管理页）
      if (admin)
        'shares': _shareTable.values.map((s) => s.toJson()).toList(),
    });
  }

  /// 更换管理员：配对用户申请成为本电脑端管理员
  /// （覆盖持久化管理员手机号；原管理员下次连接自动降级为普通用户）
  void _handleClaimAdmin(String clientId) {
    final user = _userByClientId(clientId);
    if (user == null || user.shareOnly || user.phone.isEmpty) {
      _sendTo(clientId, {
        'type': 'user:claim-result',
        'ok': false,
        'error': '仅配对连接用户可更换管理员',
      });
      return;
    }
    if (adminPhone == user.phone) {
      // 已是该手机号的管理员：补齐标记即可
      user.isAdmin = true;
    } else {
      // 原管理员降级（包括 isAdmin 标记与持久化手机号）
      for (final u in users.values) {
        if (u.isAdmin) u.isAdmin = false;
      }
      adminPhone = user.phone;
      adminDeviceId = user.deviceId;
      user.isAdmin = true;
      unawaited(_saveAdminPhone(user.phone));
      AppLog.i('host', '管理员已更换: ${user.name} (${user.phone})');
    }
    // 推送最新身份给所有在线客户端（原管理员手机端实时降级）
    for (final u in users.values.where((u) => u.online)) {
      _pushUserList(u.clientId!);
    }
    _sendTo(clientId, {'type': 'user:claim-result', 'ok': true});
  }

  void _handleCreateShare(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) {
      _sendTo(clientId,
          {'type': 'user:share-result', 'ok': false, 'error': '仅管理员可执行此操作'});
      return;
    }
    final deviceId = msg['deviceId']?.toString() ?? '';
    final phone = msg['phone']?.toString() ?? '';
    final folder = msg['folder']?.toString() ?? '';
    final perms = (msg['perms'] as List? ?? [])
        .map((e) => e.toString())
        .where((e) => ['download', 'upload', 'delete'].contains(e))
        .toList();
    final share = createShare(
      deviceId: deviceId.isEmpty ? null : deviceId,
      phone: phone.isEmpty ? null : phone,
      folder: folder,
      perms: perms,
    );
    _sendTo(clientId, {
      'type': 'user:share-result',
      'ok': share != null,
      'error': share == null ? '目录不存在或用户无效' : null,
      if (share != null) 'share': share.toJson(),
    });
  }

  void _handleRemoveShare(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) {
      _sendTo(clientId,
          {'type': 'user:share-result', 'ok': false, 'error': '仅管理员可执行此操作'});
      return;
    }
    removeShare(msg['token']?.toString() ?? '');
    _sendTo(clientId, {'type': 'user:share-result', 'ok': true});
  }

  void _handleUpdateSharePerms(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) {
      _sendTo(clientId,
          {'type': 'user:share-result', 'ok': false, 'error': '仅管理员可执行此操作'});
      return;
    }
    final token = msg['token']?.toString() ?? '';
    final perms = (msg['perms'] as List? ?? [])
        .map((e) => e.toString())
        .where((e) => ['download', 'upload', 'delete'].contains(e))
        .toList();
    updateSharePerms(token, perms);
    _sendTo(clientId, {'type': 'user:share-result', 'ok': true});
  }

  void _handleUserKick(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) return;
    final deviceId = msg['deviceId']?.toString() ?? '';
    kickUser(deviceId);
    _sendTo(clientId, {'type': 'user:kick-result', 'ok': true});
  }

  void _handleUserRemove(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) return;
    final deviceId = msg['deviceId']?.toString() ?? '';
    removeUser(deviceId);
    _sendTo(clientId, {'type': 'user:remove-result', 'ok': true});
  }

  void _handleAttachShare(String clientId, Map<String, dynamic> msg) {
    final token = msg['token']?.toString() ?? '';
    final ok = attachShare(clientId, token);
    _sendTo(clientId, {
      'type': 'user:share-result',
      'ok': ok,
      'error': ok ? null : '共享码无效',
      if (ok) 'share': _shareTable[token]?.toJson(),
    });
  }

  // ── 文件操作 ────────────────────────────────────────────
  // 手机端请求文件列表（share 非空=共享目录模式）
  Future<void> _handleFileList(
      String clientId, String pathStr, String requestId,
      {String? share}) async {
    // 共享目录模式
    if (share != null && share.isNotEmpty) {
      final shareCfg = _checkShare(clientId, share);
      if (shareCfg == null) {
        _sendTo(clientId, {
          'type': 'file-list-result',
          'files': <dynamic>[],
          'error': '无该共享目录权限',
          'requestId': requestId,
        });
        return;
      }
      final dir = _dirAtShared(shareCfg, pathStr);
      if (dir == null || !await dir.exists()) {
        _sendTo(clientId, {
          'type': 'file-list-result',
          'files': <dynamic>[],
          'error': '共享目录不存在',
          'requestId': requestId,
        });
        return;
      }
      try {
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
        _sendTo(clientId, {
          'type': 'file-list-result',
          'files': list,
          'requestId': requestId,
          'share': share,
          // 共享权限透传给手机端（决定显示哪些操作按钮）
          'perms': shareCfg.perms,
        });
      } catch (e) {
        _sendTo(clientId, {
          'type': 'file-list-result',
          'files': <dynamic>[],
          'error': '读取共享目录失败: $e',
          'requestId': requestId,
        });
      }
      return;
    }
    // 主共享模式：仅管理员可访问
    if (!_isAdmin(clientId)) {
      _sendTo(clientId, {
        'type': 'file-list-result',
        'files': <dynamic>[],
        'error': '无访问权限，请扫描管理员分享的二维码',
        'requestId': requestId,
      });
      return;
    }
    try {
      // 「我的电脑」虚拟根：返回盘符 + 特殊文件夹
      if (myComputerMode && pathStr.isEmpty) {
        _sendTo(clientId, {
          'type': 'file-list-result',
          'files': _myComputerEntries().map((e) => e.toJson()).toList(),
          'requestId': requestId,
        });
        return;
      }
      final dir = _dirAt(pathStr);
      if (dir == null) {
        _sendTo(clientId, {
          'type': 'file-list-result',
          'files': <dynamic>[],
          'error': '电脑端尚未选择共享目录',
          'requestId': requestId,
        });
        return;
      }
      if (!await dir.exists()) {
        _sendTo(clientId, {
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
      _sendTo(clientId,
          {'type': 'file-list-result', 'files': list, 'requestId': requestId});
    } catch (e) {
      _sendTo(clientId, {
        'type': 'file-list-result',
        'files': <dynamic>[],
        'error': '读取目录失败: $e',
        'requestId': requestId,
      });
    }
  }

  // 手机端请求下载 → 发送文件（支持断点续传：offset > 0 时从偏移处发送）
  Future<void> _handleFileDownload(String clientId, Map<String, dynamic> msg) async {
    final shareToken = msg['share']?.toString();
    ShareConfig? share;
    if (shareToken != null && shareToken.isNotEmpty) {
      share = _checkShare(clientId, shareToken);
      if (share == null || !share.canDownload) {
        _sendTo(clientId, {
          'type': 'file-ack',
          'fileName': msg['fileName'],
          'success': false,
          'reason': 'no-perm',
        });
        return;
      }
    } else if (!_isAdmin(clientId)) {
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': msg['fileName'],
        'success': false,
        'reason': 'no-perm',
      });
      return;
    }
    if (_sendingClients.contains(clientId)) {
      AppLog.e('download', '拒绝发送(busy): ${msg['fileName']} [$clientId]');
      _sendTo(clientId,
          {'type': 'file-ack', 'fileName': msg['fileName'], 'success': false});
      return;
    }
    _sendingClients.add(clientId);
    var sentBytes = 0; // 诊断：断链时记录已发送字节数
    try {
      final pathStr = msg['path']?.toString() ?? '';
      // 兼容：绝对路径（我的电脑模式）与相对路径（手动模式/旧版）；
      // 兼容 '/' 与 Windows 反斜杠 '\'（手机端断点记录的可能为 file.path 原样）
      final slash = pathStr.lastIndexOf(RegExp(r'[/\\]'));
      final dirPart = slash > 0 ? pathStr.substring(0, slash) : '';
      final fileName =
          slash >= 0 ? pathStr.substring(slash + 1) : pathStr;
      final dir = share != null
          ? _dirAtShared(share, dirPart)
          : _dirAt(dirPart);
      if (dir == null) {
        _sendTo(clientId,
            {'type': 'file-ack', 'fileName': fileName, 'success': false});
        return;
      }
      final file =
          File('${dir.path}${Platform.pathSeparator}$fileName');
      if (!await file.exists()) {
        _sendTo(clientId,
            {'type': 'file-ack', 'fileName': fileName, 'success': false});
        return;
      }
      final size = await file.length();
      final offset = msg['offset'] is int ? msg['offset'] as int : 0;
      final start = offset.clamp(0, size); // 手机端断点续传起点（不超文件大小）
      final totalChunks = (size / kChunkSize).ceil();
      AppLog.i('download', '开始发送: $fileName size=${size}B offset=$start [$clientId]');
      _addTransfer(fileName, 'download', size, clientId).transferred = start;

      _sendTo(clientId, {
        'type': 'file-meta',
        'fileName': fileName,
        'fileSize': size,
        'totalChunks': totalChunks,
        // 电脑端文件路径：手机端断线后自动续传定位用（曾缺失导致下载无法续传）
        'path': file.path,
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
          // 通道活性检查：手机端断开/通道关闭时立即中止发送，
          // 避免通道关闭后数据被静默丢弃、循环飞速跑完仍报"发送完成"（假完成）；
          // 手机端 recv-error（存储不足等）也在此中止
          final session = _service.sessions[clientId];
          if (session == null || !session.isOpen || session.abortRequested) {
            throw Exception('数据通道已关闭或手机端中止，终止发送: $fileName [$clientId]');
          }
          // 背压控制
          final buffered = session.bufferedAmount;
          while (buffered > kBackpressureLimit) {
            await Future.delayed(const Duration(milliseconds: 5));
            // 等待期间通道可能关闭：中止等待避免死循环
            final s = _service.sessions[clientId];
            if (s == null || !s.isOpen || s.abortRequested) {
              throw Exception('等待背压期间通道关闭或手机端中止，终止发送: $fileName [$clientId]');
            }
          }
          // 服务器中转(relay)时限速 500KB/s；P2P 直连不限速
          await _service.waitSendPermit(clientId, piece.length);
          // await 发送完成：send 失败（通道关闭/缓冲满）时立即感知并中止，
          // 杜绝数据静默丢失导致的“假完成”（曾实测 1.75GB 差 190 万字节）
          await _service.sendBinaryTo(clientId, piece);
          t.transferred += piece.length;
          sentBytes = t.transferred;
          t.speed = _fmtSpeed(t.transferred - start, startMs);
          // 诊断：每 2MB 记录一次发送进度与积压（断链前观察速率/背压）
          if (t.transferred - _sentLogBytes >= 2 * 1024 * 1024) {
            _sentLogBytes = t.transferred;
            final s2 = _service.sessions[clientId];
            AppLog.i('download',
                '发送进度: $fileName ${t.transferred}/$size B buffered=${s2?.bufferedAmount ?? -1}B');
          }
          notifyListeners();
        }
      }
      // await 发送完成：file-complete 是手机端收尾/校验的触发消息，
      // 发送失败必须感知（丢失会导致手机端卡住直至 30s 超时续传）
      await _sendTo(clientId,
          {'type': 'file-complete', 'fileName': fileName, 'fileSize': size});
      t.status = 'done';
      AppLog.i('download', '发送完成: $fileName (${t.transferred}/${size}B) [$clientId]');
      notifyListeners();
    } catch (e) {
      AppLog.e('download',
          '发送异常: ${msg['fileName']} 已发送=$sentBytes B', e);
      _sendTo(clientId,
          {'type': 'file-ack', 'fileName': msg['fileName'], 'success': false});
    } finally {
      _sendingClients.remove(clientId);
      _sentLogBytes = 0; // 重置进度日志基准
      _service.sessions[clientId]?.abortRequested = false;
    }
  }

  // 手机端上传文件头：先检查重名冲突，无冲突直接开始接收
  Future<void> _handleFileUpload(String clientId, Map<String, dynamic> msg) async {
    final fileName = msg['fileName']?.toString();
    if (fileName == null || fileName.isEmpty) return;
    final shareToken = msg['share']?.toString();
    ShareConfig? share;
    if (shareToken != null && shareToken.isNotEmpty) {
      share = _checkShare(clientId, shareToken);
      if (share == null || !share.canUpload) {
        _sendTo(clientId, {
          'type': 'file-ack',
          'fileName': fileName,
          'requestId': msg['requestId']?.toString() ?? '',
          'success': false,
          'reason': 'no-perm',
        });
        return;
      }
    } else if (!_isAdmin(clientId)) {
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': msg['requestId']?.toString() ?? '',
        'success': false,
        'reason': 'no-perm',
      });
      return;
    }
    final reqOffset = msg['offset'] is int ? msg['offset'] as int : 0;
    AppLog.i('upload', '收到上传请求: $fileName size=${msg['fileSize']} offset=$reqOffset subPath=${msg['subPath']} share=${share?.name} [$clientId]');
    var rs = _recvStates[clientId];
    if (rs == null) {
      rs = _RecvState();
      _recvStates[clientId] = rs;
    }
    rs.lastChunkAt = DateTime.now(); // 握手起计时，接收超时兜底
    // 注意：此处绝不能清除 _finalizePending——上一个文件的 file-complete 可能先于其写流
    // 就绪到达（标记待补做校验），若被新请求清掉，该文件将永远收不到 ack 而卡住
    if (rs.fileName != null || rs.conflictPending) {
      // 已有传输或冲突等待中，拒绝新请求（正常串行发送下不会触发）
      AppLog.e('upload', '拒绝上传(busy): $fileName 当前接收=${rs.fileName} [$clientId]');
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': msg['requestId']?.toString() ?? '',
        'success': false,
        'reason': 'busy',
      });
      return;
    }
    // 手动模式未选共享目录才拒绝；「我的电脑」模式目录由路径直接解析
    if (sharedDir == null && !myComputerMode && share == null) {
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'success': false,
        'reason': 'no-dir',
      });
      return;
    }
    rs.fileName = fileName;
    rs.requestId = msg['requestId']?.toString() ?? '';
    rs.expected = msg['fileSize'] is int ? msg['fileSize'] as int : 0;
    rs.subPath = msg['subPath']?.toString() ?? '';
    rs.bytes = 0;
    rs.startMs = DateTime.now().millisecondsSinceEpoch;
    rs.share = share;

    try {
      final dir = share != null
          ? _dirAtShared(share, rs.subPath ?? '')
          : _dirAt(rs.subPath ?? '');
      if (dir == null) throw Exception('未找到保存目录');
      if (!await dir.exists()) await dir.create(recursive: true);
      final target = File('${dir.path}${Platform.pathSeparator}$fileName');
      // 续传请求（offset>0）跳过重名冲突检测：目标正式文件已存在时仍按
      // .part 实际大小续传（_beginUpload 回包 offset 以磁盘为准），
      // 否则中断后重连的续传请求会反复被 conflict 拦截而永远传不完
      if (reqOffset == 0 && await target.exists()) {
        // 文件名冲突：通知手机端等待用户决策（期间到达的块由缓存兜底）
        AppLog.i('upload', '文件名冲突，等待手机端决策: $fileName [$clientId]');
        rs.conflictPending = true;
        _sendTo(clientId, {
          'type': 'file:conflict',
          'fileName': fileName,
          'requestId': rs.requestId,
        });
        return;
      }
      await _beginUpload(clientId, reqOffset: reqOffset);
    } catch (e) {
      rs.fileName = null;
      rs.pendingChunks.clear();
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': rs.requestId,
        'success': false,
        'reason': 'no-dir',
      });
    }
  }

  // 初始化接收并告知手机端可以发送数据
  // 断点续传：优先基于磁盘上已有的 .part 实际大小续写（以电脑端为准），
  // accept 回包携带 offset，手机端据此从偏移继续发送
  Future<void> _beginUpload(String clientId,
      {String? saveAs, int reqOffset = 0}) async {
    final rs = _recvStates[clientId];
    if (rs == null) return;
    final fileName = rs.fileName!;
    final saveName = saveAs ?? fileName;
    rs.conflictPending = false;
    AppLog.i('upload', '初始化接收流: $fileName (保存名: $saveName) 请求offset=$reqOffset [$clientId]');
    try {
      final dir = rs.share != null
          ? _dirAtShared(rs.share!, rs.subPath ?? '')
          : _dirAt(rs.subPath ?? '');
      if (dir == null) throw Exception('共享目录未选择');
      if (!await dir.exists()) await dir.create(recursive: true);
      final partFile = File('${dir.path}${Platform.pathSeparator}$saveName.p2p.part');
      // 续传基准：.part 实际大小（磁盘为准）
      // - 请求 offset>0（续传意图）：以 .part 为准；.part 缺失/异常时从头并告警
      // - 请求 offset==0（全新上传）：删除残留 .part 从头写，
      //   否则 append 会写入手机端从头发送的重复数据导致文件损坏
      var baseOffset = 0;
      if (partFile.existsSync()) {
        final len = await partFile.length();
        if (len > 0 && len < rs.expected) {
          baseOffset = len;
          if (reqOffset > 0 && reqOffset != len) {
            AppLog.w('upload', '续传起点不一致: 请求=$reqOffset 磁盘.part=$len，以磁盘为准 [$clientId]');
          }
        } else {
          AppLog.w('upload', '.part异常(len=$len, expected=${rs.expected})，从头接收 [$clientId]');
        }
      } else if (reqOffset > 0) {
        AppLog.w('upload', '续传请求 offset=$reqOffset 但 .part 不存在，从头接收 [$clientId]');
      }
      if (baseOffset == 0 && partFile.existsSync()) {
        try {
          await partFile.delete();
          AppLog.i('upload', '删除残留.part（全新/从头接收）: ${partFile.path} [$clientId]');
        } catch (e) {
          AppLog.e('upload', '删除残留.part失败: ${partFile.path}', e);
        }
      }
      rs.file = partFile;
      rs.sink = partFile.openWrite(
          mode: baseOffset > 0 ? FileMode.append : FileMode.write);
      rs.bytes = baseOffset;
      rs.currentUploadItem = _addTransfer(fileName, 'upload', rs.expected, clientId);
      rs.currentUploadItem!.transferred = baseOffset;
      // 补写初始化期间缓存的块
      if (rs.pendingChunks.isNotEmpty) {
        for (final c in rs.pendingChunks) {
          rs.sink!.add(c);
          rs.bytes += c.length;
        }
        rs.pendingChunks.clear();
        rs.pendingBytes = 0;
        final t = rs.currentUploadItem;
        if (t != null && t.direction == 'upload') {
          t.transferred = rs.bytes;
          t.speed = _fmtSpeed(rs.bytes - baseOffset, rs.startMs);
        }
      }
      AppLog.i('upload', '发送accept: $fileName offset=$baseOffset [$clientId]');
      _sendTo(clientId, {
        'type': 'file:accept',
        'fileName': fileName,
        'requestId': rs.requestId,
        // 实际续传起点（0 表示从头接收）；手机端据此定位读取
        if (baseOffset > 0) 'offset': baseOffset,
        if (saveName != fileName) 'saveAs': saveName,
      });
      // 初始化期间 file-complete 已到达：补做完成校验与回包（避免手机端永久等待）
      if (rs.finalizePending) {
        rs.finalizePending = false;
        await _finalizeUpload(clientId);
      }
    } catch (e) {
      rs.finalizePending = false;
      rs.fileName = null;
      rs.pendingChunks.clear();
      rs.pendingBytes = 0;
      AppLog.e('upload', '初始化接收失败(no-dir): $fileName [$clientId]', e);
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': rs.requestId,
        'success': false,
        'reason': 'no-dir',
      });
    }
  }

  // 手机端回应文件名冲突决策
  Future<void> _handleConflictResolve(String clientId, Map<String, dynamic> msg) async {
    final rs = _recvStates[clientId];
    if (rs == null) return;
    final fileName = msg['fileName']?.toString();
    if (fileName == null || fileName != rs.fileName || !rs.conflictPending) {
      return;
    }
    // 带 requestId 时校验一致性，避免旧决策影响新传输
    final rid = msg['requestId']?.toString();
    if (rid != null && rid.isNotEmpty && rid != rs.requestId) return;
    final action = msg['action']?.toString() ?? 'skip';
    if (action == 'skip') {
      rs.conflictPending = false;
      rs.skipUploading = true; // 丢弃数据块，file-complete 时回 ack skipped
      return;
    }
    if (action == 'rename') {
      final saveAs = _autoRename(clientId, fileName);
      await _beginUpload(clientId, saveAs: saveAs);
    } else {
      await _beginUpload(clientId); // overwrite
    }
  }

  // 自动生成不冲突的文件名：name (1).ext、name (2).ext ...
  String _autoRename(String clientId, String fileName) {
    final rs = _recvStates[clientId];
    final dir = rs?.share != null
        ? _dirAtShared(rs!.share!, rs.subPath ?? '')
        : _dirAt(rs?.subPath ?? '');
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final ext = dot > 0 ? fileName.substring(dot) : '';
    for (var i = 1; ; i++) {
      final candidate = '$base ($i)$ext';
      final f = File('${dir!.path}${Platform.pathSeparator}$candidate');
      if (!f.existsSync()) return candidate;
    }
  }

  // 二进制块（上传数据，按客户端路由）
  void _onBinary(String clientId, Uint8List bytes) {
    final rs = _recvStates[clientId];
    if (rs == null || rs.sink == null) {
      // 用户选择跳过：直接丢弃，不缓存
      if (rs?.skipUploading == true) return;
      // 接收初始化中（异步打开写流）：缓存块，就绪后补写，避免丢块
      if (rs != null && rs.fileName != null && rs.expected > 0) {
        rs.pendingChunks.add(bytes);
        rs.pendingBytes += bytes.length;
        if (rs.pendingBytes > kPendingChunkLimit) {
          // 写流长时间未就绪（异常）：放弃本次接收，避免内存无限增长
          final fname = rs.fileName;
          final rid = rs.requestId;
          rs.fileName = null;
          rs.expected = 0;
          rs.pendingChunks.clear();
          rs.pendingBytes = 0;
          rs.conflictPending = false;
          rs.finalizePending = false; // 本次接收已放弃，不再补做校验
          _sendTo(clientId, {
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
    if (rs.skipUploading) return;
    rs.lastChunkAt = DateTime.now();
    // 超量防护：已收满 expected 后仍到达的数据块视为异常
    // （手机端起点错位/重复发送），丢弃并记录，避免文件无限膨胀
    if (rs.expected > 0 && rs.bytes >= rs.expected) {
      rs.overflowBytes += bytes.length;
      AppLog.w('upload', '超量数据丢弃: ${rs.fileName} 已收=${rs.bytes}/${rs.expected} 溢出+${bytes.length}B [$clientId]');
      return;
    }
    rs.sink!.add(bytes);
    rs.bytes += bytes.length;
    final t = rs.currentUploadItem ??
        (transfers.isNotEmpty ? transfers.last : null);
    if (t != null && t.status == 'transferring' && t.direction == 'upload') {
      t.transferred = rs.bytes;
      t.speed = _fmtSpeed(rs.bytes, rs.startMs);
      if (rs.bytes - rs.lastLogBytes >= 8 * 1024 * 1024) {
        rs.lastLogBytes = rs.bytes;
        AppLog.i('upload', '进度: ${rs.fileName} ${rs.bytes}/${rs.expected}B (${t.speed}) [$clientId]');
      }
      notifyListeners();
    }
  }

  // 上传完成
  Future<void> _finalizeUpload(String clientId) async {
    final rs = _recvStates[clientId];
    if (rs == null) return;
    // 快照接收状态：本函数在 flush/close 处异步挂起期间，
    // 下一个文件的 file:upload 会重置这些全局状态，必须用快照完成校验与回包
    final fileName = rs.fileName;
    final requestId = rs.requestId;
    final recvBytes = rs.bytes;
    final recvExpected = rs.expected;
    final subPath = rs.subPath;
    final item = rs.currentUploadItem;
    final sink = rs.sink;
    final share = rs.share;
    final overflow = rs.overflowBytes;
    if (sink == null) {
      // 写流尚未就绪（_beginUpload 初始化挂起中）：
      // 标记待完成，由 _beginUpload 就绪后补做校验与回包
      if (rs.fileName != null && recvExpected > 0) {
        rs.finalizePending = true;
        return;
      }
      // 完全无接收状态（块被丢弃/消息错乱）：回失败，避免手机端永久等待
      rs.pendingBytes = 0;
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': false,
        'reason': 'no-recv',
      });
      notifyListeners();
      return;
    }
    rs.sink = null;
    rs.fileName = null;
    rs.currentUploadItem = null;
    rs.pendingChunks.clear();
    rs.pendingBytes = 0;
    rs.conflictPending = false;
    if (rs.skipUploading) {
      // 用户选择跳过：无文件落地，告知手机端
      rs.skipUploading = false;
      _sendTo(clientId, {
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
      final ok = recvBytes == recvExpected && overflow == 0;
      final saveName = fileName; // 正常接收时保存名即文件名
      AppLog.i('upload', '接收完成: $fileName $recvBytes/$recvExpected B 溢出=${overflow}B => ${ok ? '成功' : '失败(字节数不匹配/超量)'} [$clientId]');
      if (item != null) {
        item.status = ok ? 'done' : 'error';
      }
      // 成功：.part 重命名为正式文件名；失败：删除残留 part
      final part = rs.file;
      if (ok && part != null) {
        try {
          final dir = share != null
              ? _dirAtShared(share, subPath ?? '')
              : _dirAt(subPath ?? '');
          var finalName = saveName ?? '';
          if (dir != null) {
            final target = File('${dir.path}${Platform.pathSeparator}$finalName');
            if (await target.exists()) {
              // 极端情况：传输期间正式名已存在（外部创建），自动改名
              finalName = _autoRename(clientId, finalName);
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
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': ok,
        if (!ok) 'reason': 'size-mismatch',
      });
      if (ok && sharedDir != null && (subPath ?? '').isEmpty) refreshLocalFiles();
    } catch (e) {
      AppLog.e('upload', '完成校验异常: $fileName', e);
      _sendTo(clientId, {
        'type': 'file-ack',
        'fileName': fileName,
        'requestId': requestId,
        'success': false,
      });
    }
    notifyListeners();
  }

  // 手机端删除共享目录中的文件/目录（需 delete 权限）
  Future<void> _handleFileDelete(String clientId, Map<String, dynamic> msg) async {
    final shareToken = msg['share']?.toString();
    final pathStr = msg['path']?.toString() ?? '';
    final isDir = msg['isDirectory'] == true;
    ShareConfig? share;
    if (shareToken != null && shareToken.isNotEmpty) {
      share = _checkShare(clientId, shareToken);
      if (share == null || !share.canDelete) {
        _sendTo(clientId, {
          'type': 'file-delete-result',
          'path': pathStr,
          'success': false,
          'error': '无删除权限',
        });
        return;
      }
    } else if (!_isAdmin(clientId)) {
      _sendTo(clientId, {
        'type': 'file-delete-result',
        'path': pathStr,
        'success': false,
        'error': '无删除权限',
      });
      return;
    }
    final slash = pathStr.lastIndexOf('/');
    final dirPart = slash > 0 ? pathStr.substring(0, slash) : '';
    final name = slash >= 0 ? pathStr.substring(slash + 1) : pathStr;
    final dir = share != null ? _dirAtShared(share, dirPart) : _dirAt(dirPart);
    if (dir == null || name.isEmpty) {
      _sendTo(clientId, {
        'type': 'file-delete-result',
        'path': pathStr,
        'success': false,
        'error': '路径无效',
      });
      return;
    }
    try {
      final target = File('${dir.path}${Platform.pathSeparator}$name');
      if (isDir) {
        final d = Directory('${dir.path}${Platform.pathSeparator}$name');
        if (!await d.exists()) throw Exception('目录不存在');
        await d.delete(recursive: true);
      } else {
        if (!await target.exists()) throw Exception('文件不存在');
        await target.delete();
      }
      AppLog.i('delete', '删除成功: $pathStr [$clientId]');
      _sendTo(clientId, {'type': 'file-delete-result', 'path': pathStr, 'success': true});
    } catch (e) {
      AppLog.e('delete', '删除失败: $pathStr', e);
      _sendTo(clientId, {
        'type': 'file-delete-result',
        'path': pathStr,
        'success': false,
        'error': '删除失败: $e',
      });
    }
  }

  // ── 辅助 ────────────────────────────────────────────────
  TransferItem _addTransfer(String name, String direction, int total, String clientId) {
    final user = _userByClientId(clientId);
    final t = TransferItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: name,
      direction: direction,
      total: total,
      startTime: DateTime.now(),
      clientName: user?.name ?? '手机',
      clientId: clientId,
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
    _recvTimeoutTimer?.cancel();
    _recvStates.clear();
    _sendingClients.clear();
    _service.dispose();
    super.dispose();
  }
}
