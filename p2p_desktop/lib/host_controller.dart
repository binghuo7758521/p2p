import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'auto_login.dart';
import 'host_service.dart';
import 'known_folder.dart';
import 'models.dart';
import 'protocol.dart';
import 'update_service.dart';

/// 电脑端连接状态
enum HostState {
  idle, // 未连接
  registered, // 已注册（配对码就绪，等待手机）
  peerConnected, // 手机已连接
  lost, // 连接断开
  offline, // 主动离线（不注册、不接受手机端连接，本地功能可用）
}

/// 共享配置：管理员给某个用户（设备或手机号）共享的一个文件夹
class ShareConfig {
  final String token; // 共享码（二维码内容的一部分）
  final String folder; // 共享文件夹绝对路径（/ 分隔）
  final List<String> perms; // ['download','upload','delete']
  String? targetDeviceId; // 目标用户设备 id（null=未绑定/公开）
  final String? targetPhone; // 目标用户手机号（null=未指定/公开）
  String remark = ''; // 备注名称（v6.15+：管理员填写，展示优先于文件夹名）

  ShareConfig({
    required this.token,
    required this.folder,
    required this.perms,
    this.targetDeviceId,
    this.targetPhone,
    this.remark = '',
  });

  /// 展示名称：备注优先，其次文件夹末段（“共享给我的”不显示全路径）
  String get name => remark.isNotEmpty ? remark : folder.split('/').last;

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
        if (remark.isNotEmpty) 'remark': remark,
      };

  factory ShareConfig.fromJson(Map<String, dynamic> json) => ShareConfig(
        token: json['token']?.toString() ?? '',
        folder: json['folder']?.toString() ?? '',
        perms: (json['perms'] as List? ?? [])
            .map((e) => e.toString())
            .toList(),
        targetDeviceId: json['targetDeviceId']?.toString(),
        targetPhone: json['targetPhone']?.toString(),
        remark: json['remark']?.toString() ?? '',
      );
}

/// 手机端用户（多用户管理）
class HostUser {
  String deviceId;
  String name;
  String? clientId; // 当前 socket 会话 id（在线时非空）
  String phone = ''; // 历史登录手机号（v5.8 及以前；v5.9+ 去手机号后不再上报）
  bool isAdmin;
  bool shareOnly = false; // 共享访客（扫码共享加入）：永不成为管理员
  String passwordHash = ''; // 连接密码哈希（空=未设置，连接不校验）
  bool pendingReset = false; // 管理员已重置密码，下次连接需用新密码
  String remark = ''; // 备注名称（管理员填写，展示优先于设备名）
  final List<ShareConfig> shares = [];
  final DateTime joinedAt;

  HostUser({
    required this.deviceId,
    required this.name,
    this.clientId,
    this.isAdmin = false,
    DateTime? joinedAt,
  }) : joinedAt = joinedAt ?? DateTime.now();

  /// 展示名称：备注优先，其次设备上报名
  String get displayName => remark.isNotEmpty ? remark : name;

  bool get online => clientId != null;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'name': name,
        'phone': phone,
        'isAdmin': isAdmin,
        'shareOnly': shareOnly,
        'passwordHash': passwordHash,
        'pendingReset': pendingReset,
        'remark': remark,
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
        ..passwordHash = json['passwordHash']?.toString() ?? ''
        ..pendingReset = json['pendingReset'] == true
        ..remark = json['remark']?.toString() ?? ''
        ..shares.addAll((json['shares'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ShareConfig.fromJson(Map<String, dynamic>.from(e))));
}

/// 激活码（v5.9+）：电脑端本地生成并同步服务器，手机端凭码激活
class ActCodeEntry {
  final String code; // 8 位大写字母+数字
  final String type; // admin=管理员码（v6.14+ 仅此一种）
  final DateTime createdAt;
  bool used; // 已被手机端兑换（服务器通知）

  ActCodeEntry({
    required this.code,
    required this.type,
    required this.createdAt,
    this.used = false,
  });

  bool get isAdmin => type == 'admin';

  Map<String, dynamic> toJson() => {
        'code': code,
        'type': type,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'used': used,
      };

  factory ActCodeEntry.fromJson(Map<String, dynamic> json) => ActCodeEntry(
        code: json['code']?.toString() ?? '',
        type: json['type']?.toString() == 'admin' ? 'admin' : 'normal',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            json['createdAt'] is int ? json['createdAt'] as int : 0),
        used: json['used'] == true,
      );
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
  bool _kfPathLogged = false; // 特殊文件夹路径解析日志只打一次（v6.30+）

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
  String? adminDeviceId; // 管理员设备（管理员码激活 + 电脑端确认后产生）
  String? legacyAdminPhone; // 兼容旧版 admin.json 中的手机号记录

  // ── 激活码（v5.9+） ─────────────────────────────────────
  final Map<String, ActCodeEntry> _actCodes = {}; // code -> 激活码

  /// 全部激活码（管理页展示：类型/状态/时间，可撤销）
  List<ActCodeEntry> get actCodeList => _actCodes.values.toList();

  /// 待确认的管理员激活/移交请求（UI 弹窗确认后 approve/reject）
  Map<String, dynamic>? pendingAdminApproval; // {deviceId, name, claim?}

  /// 首启展示的管理员激活码（无管理员时自动生成，激活/撤销后重新生成）
  String? _bootAdminCode;

  /// 曾通过管理员码授权过的设备（持久化）：被更换降级后重连不再触发
  /// “更换管理员”弹窗，也免于被 loadUsers 当作历史普通用户清除
  final Set<String> _grantedAdminDevices = {};

  /// 是否已有管理员（含持久化恢复）
  bool get hasAdmin => adminDeviceId != null && adminDeviceId!.isNotEmpty;

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

  /// 当前连接方式原始值（'relay'|'direct'|'probing'|''），传输记录快照用
  String get connTypeRaw {
    for (final s in _service.sessions.values) {
      if (s.isOpen) return s.connectionType;
    }
    return '';
  }

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
    // v6.23+ 及时升级：服务器推送新版通知 → 立即检查升级（不等 6 小时定时）
    _service.onUpgradeNotify = () => UpdateService.instance.checkNow();
    // v6.24+ 服务器拒绝注册：版本已不再支持 → 触发检查弹强制升级窗（force）
    _service.onVersionNotSupported = (minVersion) {
      AppLog.i('host', '版本已不再支持（最低 v$minVersion），触发强制升级检查');
      UpdateService.instance.checkNow();
    };
    // v6.26+ 管理员手机端确认升级：跳过确认窗直接静默升级，
    // 失败时上报服务器转发给管理员手机端（成功时进程重启退出）
    _service.onUpgradeConfirmed = (latest) {
      AppLog.i('host', '管理员已确认升级到 v$latest，开始静默升级');
      unawaited(UpdateService.instance.upgradeNow(
        onResult: (ok, error) {
          if (!ok) _service.reportUpgradeResult(false, error);
        },
      ));
    };
    _service.onRegistered = (code) {
      pairCode = code;
      state = HostState.registered;
      AppLog.i('host', '注册成功: 配对码=$code');
      notifyListeners();
      // v5.0+：注册后全量同步共享配置到服务器（手机端免配对码列表依赖）
      unawaited(_syncSharesToServer());
    };
    _service.onClientJoined = (info) async {
      final clientInfo = info['clientInfo'];
      final cInfo = clientInfo is Map
          ? Map<String, dynamic>.from(clientInfo)
          : <String, dynamic>{};
      final clientId = cInfo['id']?.toString() ?? '';
      final deviceId = cInfo['deviceId']?.toString() ?? clientId;
      final name = cInfo['name']?.toString() ?? '手机';
      final activationCode = cInfo['activationCode']?.toString();
      final shareToken = cInfo['shareToken']?.toString();
      final turn = info['turn'];
      _service.turnConfig = turn is Map
          ? Map<String, dynamic>.from(turn)
          : null;
      AppLog.i('host',
          '手机端加入: $name (deviceId=$deviceId 激活码=${activationCode != null && activationCode.isNotEmpty ? '有' : '无'} share=$shareToken)');
      _ensureUser(
          deviceId: deviceId,
          name: name,
          clientId: clientId,
          activationCode: activationCode,
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
    // 激活码被手机端兑换：管理页标记已用
    _service.onCodeUsed = markActCodeUsed;
  }

  // ── 用户管理 ────────────────────────────────────────────
  /// 校验共享目标是否匹配该用户（设备 id；未指定=公开）
  bool _canBind(ShareConfig share, String deviceId) {
    if (share.targetDeviceId != null && share.targetDeviceId != deviceId) {
      return false;
    }
    return true;
  }

  /// 手机端加入时确保用户存在（v6.14+ 身份二态化：仅管理员/共享访客）：
  /// - 管理员仅从「管理员激活码」产生：无管理员时直接授权（无需电脑端
  ///   弹窗确认，码由电脑端自己展示）；已有管理员时转为更换申请
  /// - 共享访客（扫码共享）永不成为管理员；无普通码，非访客非管理员
  ///   的历史普通用户记录加载时清除
  /// - 连接密码校验由数据通道 auth:verify 完成（服务器不接触密码）
  void _ensureUser({
    required String deviceId,
    required String name,
    String? clientId,
    String? shareToken,
    String? activationCode,
  }) {
    var user = users[deviceId];
    final shareOnly = shareToken != null && shareToken.isNotEmpty;
    // 激活码类型判定（管理员码候选）；未知码按普通连接处理
    final actType = (activationCode != null && activationCode.isNotEmpty)
        ? _actCodes[activationCode]?.type
        : null;
    // 管理员码激活（非共享访客连接）：无管理员直接授权；已有管理员转更换申请
    final isAdminAct = actType == 'admin' && !shareOnly;
    if (user == null) {
      user = HostUser(deviceId: deviceId, name: name, clientId: clientId);
      user.shareOnly = shareOnly;
      // 普通连接：校验共享码（共享目标需匹配该设备或公开共享）
      final share = shareToken != null ? _shareTable[shareToken] : null;
      if (share != null && _canBind(share, deviceId)) {
        if (!user.shares.any((s) => s.token == share.token)) {
          user.shares.add(share);
        }
        AppLog.i('host', '共享码用户绑定共享: ${share.name}');
      }
      users[deviceId] = user;
      notifyListeners();
      unawaited(_saveUsers());
    } else {
      user.name = name;
      user.clientId = clientId;
      // 已存在用户带共享码连接：同样校验绑定。老用户（曾配对/历史连接）
      // 扫码加入公开或指定共享时，此处必须补绑定，否则 user.shares 为空
      // 导致“扫码后看不到文件夹”（file:list 返回无访问权限）
      if (shareOnly) {
        final share = _shareTable[shareToken];
        if (share != null && _canBind(share, deviceId)) {
          if (!user.shares.any((s) => s.token == share.token)) {
            user.shares.add(share);
            AppLog.i('host', '老用户共享码绑定共享: ${share.name}');
          }
        }
      }
      unawaited(_saveUsers());
    }
    // 管理员码激活处理：无管理员直接授权；已有管理员且是新设备转更换申请
    // （防顶替弹窗）；曾授权的降级管理员重连按普通用户处理，不再弹窗
    if (isAdminAct) {
      if (!hasAdmin && pendingAdminApproval == null) {
        user.shareOnly = false;
        _grantAdmin(user);
        AppLog.i('host', '管理员码激活，自动授权: $name ($deviceId)');
      } else if (hasAdmin &&
          pendingAdminApproval == null &&
          !_grantedAdminDevices.contains(deviceId)) {
        pendingAdminApproval = {
          'deviceId': deviceId,
          'name': name,
          'claim': true,
        };
        notifyListeners(); // 电脑端弹出“是否更换管理员”确认窗
        AppLog.i('host', '已有管理员，管理员码激活转更换申请: $name ($deviceId)');
      } else {
        AppLog.w('host',
            '已有管理员或存在待确认申请，管理员码按普通用户处理: $name');
      }
    }
  }

  // ── 管理员持久化（电脑端重启后恢复管理员身份） ──────────
  Future<File> _adminFile() async {
    final docs = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$docs\\Documents\\p2p_desktop_logs');
    await dir.create(recursive: true);
    return File('${dir.path}\\admin.json');
  }

  /// 启动/重新连接时恢复管理员设备 id（兼容旧版 adminPhone 记录）
  Future<void> _loadAdminState() async {
    try {
      final f = await _adminFile();
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString());
      if (json is! Map) return;
      // 曾授权设备集合（v6.14+）：用于避免降级管理员重连反复触发更换弹窗
      final granted = json['grantedDevices'];
      if (granted is List) {
        for (final d in granted.whereType<String>()) {
          if (d.isNotEmpty) _grantedAdminDevices.add(d);
        }
        if (_grantedAdminDevices.isNotEmpty) {
          AppLog.i('host',
              '恢复曾授权设备: ${_grantedAdminDevices.length} 台');
        }
      }
      final did = json['adminDeviceId'] is String &&
              (json['adminDeviceId'] as String).isNotEmpty
          ? json['adminDeviceId'] as String
          : null;
      if (did != null) {
        adminDeviceId = did;
        AppLog.i('host', '从本地文件恢复管理员设备: $did');
        return;
      }
      // 兼容旧格式：adminPhone → 记录后由 _loadUsers 按手机号匹配补管理员
      final phone = json['adminPhone'] is String &&
              (json['adminPhone'] as String).isNotEmpty
          ? json['adminPhone'] as String
          : null;
      if (phone != null) {
        legacyAdminPhone = phone;
        AppLog.i('host', '检测到旧版管理员手机号记录: $phone（用户加载后匹配）');
      }
    } catch (e) {
      AppLog.w('host', '读取管理员文件失败', e);
    }
  }

  Future<void> _saveAdminState() async {
    if (adminDeviceId == null || adminDeviceId!.isEmpty) return;
    try {
      final f = await _adminFile();
      await f.writeAsString(jsonEncode({
        'adminDeviceId': adminDeviceId,
        'grantedDevices': _grantedAdminDevices.toList(),
      }));
      AppLog.i('host', '管理员设备已保存: $adminDeviceId');
    } catch (e) {
      AppLog.w('host', '保存管理员文件失败', e);
    }
  }

  // ── 用户列表持久化（重启后仍可查看/管理有连接权限的手机端） ──
  Future<File> _usersFile() async {
    final docs = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$docs\\Documents\\p2p_desktop_logs');
    await dir.create(recursive: true);
    return File('${dir.path}\\users.json');
  }

  /// 启动/重新连接时恢复用户列表（全部置为离线，重新加入时再上线）
  Future<void> _loadUsers() async {
    try {
      final f = await _usersFile();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString());
      if (list is! List) return;
      var changed = false;
      for (final item in list.whereType<Map>()) {
        final u = HostUser.fromJson(Map<String, dynamic>.from(item));
        if (u.deviceId.isEmpty) continue;
        // v6.14+ 身份二态化：清除历史普通用户记录（非管理员且非共享访客，
        // 且从未被管理员码授权过——降级管理员保留，重连不再弹更换申请）
        if (!u.isAdmin &&
            !u.shareOnly &&
            !_grantedAdminDevices.contains(u.deviceId)) {
          AppLog.i('host', '清除历史普通用户记录: ${u.deviceId} (${u.name})');
          changed = true;
          continue;
        }
        u.clientId = null; // 离线状态，重新 join 时恢复在线
        // 管理员身份一致性校正（防历史脏数据/误标）：共享访客永不可能是
        // 管理员；管理员设备 id 已恢复时，仅同一设备的用户保留管理员标记
        if (u.isAdmin &&
            (u.shareOnly ||
                (adminDeviceId != null &&
                    adminDeviceId!.isNotEmpty &&
                    u.deviceId != adminDeviceId))) {
          u.isAdmin = false;
          AppLog.w('host',
              '校正管理员标记: ${u.deviceId} (shareOnly=${u.shareOnly})');
        }
        // 兼容旧版 adminPhone：匹配到该手机号的用户补为管理员
        if (!u.isAdmin &&
            legacyAdminPhone != null &&
            legacyAdminPhone!.isNotEmpty &&
            u.phone == legacyAdminPhone &&
            !u.shareOnly) {
          u.isAdmin = true;
          AppLog.i('host', '旧版管理员手机号匹配，恢复管理员身份: ${u.deviceId}');
        }
        users[u.deviceId] = u;
        if (u.isAdmin && (adminDeviceId == null || adminDeviceId!.isEmpty)) {
          adminDeviceId = u.deviceId;
        }
        changed = true;
      }
      if (changed) {
        AppLog.i('host', '从本地文件恢复用户列表: ${users.length} 台设备');
        notifyListeners();
      }
    } catch (e) {
      AppLog.w('host', '读取用户列表文件失败', e);
    }
  }

  // ── 共享配置持久化（v5.0+：重启不丢，并同步服务器供手机端免配对码拉取） ──
  Future<File> _sharesFile() async {
    final docs = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$docs\\Documents\\p2p_desktop_logs');
    await dir.create(recursive: true);
    return File('${dir.path}\\shares.json');
  }

  /// 恢复共享配置：_shareTable 全部恢复，并把已绑定用户的共享补回 user.shares
  /// （user.shares 不落盘，重启后依赖此处恢复，否则用户重连后看不到共享）
  Future<void> _loadShares() async {
    try {
      final f = await _sharesFile();
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString());
      if (json is! List) return;
      _shareTable.clear();
      for (final e in json.whereType<Map>()) {
        final s = ShareConfig.fromJson(Map<String, dynamic>.from(e));
        _shareTable[s.token] = s;
      }
      for (final s in _shareTable.values) {
        final did = s.targetDeviceId;
        if (did != null && did.isNotEmpty && users.containsKey(did)) {
          final u = users[did]!;
          if (!u.shares.any((x) => x.token == s.token)) u.shares.add(s);
        }
      }
      AppLog.i('host', '恢复共享配置: ${_shareTable.length} 条');
      notifyListeners();
    } catch (e) {
      AppLog.w('host', '读取共享配置失败', e);
    }
  }

  Future<void> _saveShares() async {
    try {
      final f = await _sharesFile();
      await f.writeAsString(jsonEncode(
          _shareTable.values.map((s) => s.toJson()).toList()));
    } catch (e) {
      AppLog.w('host', '保存共享配置失败', e);
    }
  }

  /// 全量同步共享到服务器：手机端激活后凭设备令牌拉取“共享给我的”列表，
  /// 并通过免配对码信令连接本机浏览/传输
  Future<void> _syncSharesToServer() async {
    // v6.9: 补报电脑端备注名与文件夹名（曾漏报导致服务器存默认值
    // “电脑/共享文件夹”，手机端“共享给我的”列表无法显示真实名称）
    final list = _shareTable.values
        .map((s) => {...s.toJson(), 'hostName': deviceName, 'name': s.name})
        .toList();
    await _service.syncSharesToServer(list);
  }

  /// 共享变更后统一处理：本地落盘 + 服务器同步
  void _persistShares() {
    unawaited(_saveShares());
    unawaited(_syncSharesToServer());
  }

  /// 保存用户列表（保存设备身份与连接密码哈希；shares/clientId 为内存态不落盘）
  Future<void> _saveUsers() async {
    try {
      final f = await _usersFile();
      final list = users.values
          .map((u) => {
                'deviceId': u.deviceId,
                'name': u.name,
                'phone': u.phone,
                'isAdmin': u.isAdmin,
                'shareOnly': u.shareOnly,
                'passwordHash': u.passwordHash,
                'pendingReset': u.pendingReset,
                'remark': u.remark,
                'joinedAt': u.joinedAt.millisecondsSinceEpoch,
              })
          .toList();
      await f.writeAsString(jsonEncode(list));
      AppLog.i('host', '用户列表已保存: ${list.length} 台设备');
    } catch (e) {
      AppLog.w('host', '保存用户列表失败', e);
    }
  }

  // ── 传输记录持久化（最近 7 天） ─────────────────────────
  /// 传输记录保留天数（超过自动清理）
  static const int _transferRetentionDays = 7;

  /// 传输记录持久化文件（程序重启后仍可查看最近 7 天记录）
  Future<File> _transfersFile() async {
    final docs = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$docs\\Documents\\p2p_desktop_logs');
    await dir.create(recursive: true);
    return File('${dir.path}\\transfers.json');
  }

  /// 保存传输记录（新增 / 状态落定时调用；进度刷新不触发，避免频繁写盘）
  Future<void> _saveTransfers() async {
    try {
      final f = await _transfersFile();
      await f.writeAsString(
          jsonEncode(transfers.map((t) => t.toJson()).toList()));
    } catch (e) {
      AppLog.w('transfer', '保存传输记录失败', e);
    }
  }

  /// 启动时加载历史传输记录（按保留期清理过期记录，未完成记录置为失败）
  Future<void> _loadTransfers() async {
    try {
      final f = await _transfersFile();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString());
      if (list is! List) return;
      final cutoff = DateTime.now()
          .subtract(const Duration(days: _transferRetentionDays));
      final items = list
          .whereType<Map>()
          .map((e) => TransferItem.fromJson(Map<String, dynamic>.from(e)))
          .where((t) => !t.startTime.isBefore(cutoff))
          .toList()
        ..sort((a, b) => b.startTime.compareTo(a.startTime));
      for (final t in items) {
        // 上次程序退出时正在传输的记录恢复为失败（实际传输已中断）
        if (t.status == 'transferring') t.finish('error');
      }
      transfers.addAll(items);
      AppLog.i('transfer', '加载历史传输记录: ${items.length} 条');
    } catch (e) {
      AppLog.w('transfer', '加载传输记录失败', e);
    }
  }

  /// 删除单条传输记录（v6.28+ 手动删除，含持久化）
  void removeTransfer(String id) {
    transfers.removeWhere((x) => x.id == id);
    notifyListeners();
    unawaited(_saveTransfers());
  }

  /// 清除全部传输记录（v6.28+ 一键清空，含持久化）
  void clearTransfers() {
    transfers.clear();
    notifyListeners();
    unawaited(_saveTransfers());
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

  // ── 激活码管理（v5.9+） ─────────────────────────────────
  static const String _actChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final Random _rnd = Random.secure();

  Future<File> _actCodesFile() async {
    final docs = Platform.environment['USERPROFILE'] ?? '.';
    final dir = Directory('$docs\\Documents\\p2p_desktop_logs');
    await dir.create(recursive: true);
    return File('${dir.path}\\act-codes.json');
  }

  /// 启动时恢复激活码（重启不丢；服务器以 host:register/sync 重新同步为准）
  Future<void> _loadActCodes() async {
    try {
      final f = await _actCodesFile();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString());
      if (list is! List) return;
      _actCodes.clear();
      for (final e in list.whereType<Map>()) {
        final c = ActCodeEntry.fromJson(Map<String, dynamic>.from(e));
        if (c.code.isNotEmpty) _actCodes[c.code] = c;
      }
      AppLog.i('host', '恢复激活码: ${_actCodes.length} 个');
    } catch (e) {
      AppLog.w('host', '读取激活码文件失败', e);
    }
  }

  Future<void> _persistActCodes() async {
    try {
      final f = await _actCodesFile();
      await f.writeAsString(jsonEncode(
          _actCodes.values.map((c) => c.toJson()).toList()));
    } catch (e) {
      AppLog.w('host', '保存激活码文件失败', e);
    }
  }

  /// 生成管理员激活码（8 位大写字母+数字，24 小时有效由服务器强制）
  /// v6.14+ 身份二态化：仅管理员码一种类型，不再区分普通码
  String generateActCode() {
    String code;
    do {
      code = List.generate(
          8, (_) => _actChars[_rnd.nextInt(_actChars.length)]).join();
    } while (_actCodes.containsKey(code));
    _actCodes[code] = ActCodeEntry(
        code: code,
        type: 'admin',
        createdAt: DateTime.now());
    unawaited(_persistActCodes());
    _syncActCodesToServer();
    notifyListeners();
    return code;
  }

  /// 首启展示的管理员激活码：无管理员时惰性生成并复用（已用/撤销后重生成）
  String? ensureBootAdminCode() {
    if (hasAdmin) return null;
    final cur = _bootAdminCode == null ? null : _actCodes[_bootAdminCode];
    if (cur == null || cur.used) {
      _bootAdminCode = generateActCode();
    }
    return _bootAdminCode;
  }

  /// 撤销激活码（服务器同步删除，未使用的码立即失效）
  void revokeActCode(String code) {
    if (_actCodes.remove(code) == null) return;
    unawaited(_persistActCodes());
    _syncActCodesToServer();
    notifyListeners();
  }

  /// 手机端兑换成功后服务器通知（host:code-used），标记已用
  void markActCodeUsed(String code) {
    final c = _actCodes[code];
    if (c == null || c.used) return;
    c.used = true;
    unawaited(_persistActCodes());
    notifyListeners();
  }

  /// 全量同步激活码到服务器（注册时携带 / 增删后增量同步）
  void _syncActCodesToServer() {
    _service.syncActCodes(_actCodes.values
        .map((c) => {'code': c.code, 'type': c.type})
        .toList());
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
    unawaited(_saveUsers());
    // 用户删除可能连带移除其专属共享（如设备指定共享）
    _persistShares();
  }

  // ── 连接密码 / 备注 / 更换管理员（v5.9+） ─────────────────
  String _hashPassword(String pwd) {
    // 连接密码：加盐 SHA-256 后本地存储（等保一级：密码不得明文保存）
    final salt = List.generate(8, (_) => _rnd.nextInt(10)).join();
    final h = sha256.convert(utf8.encode('$salt:$pwd')).toString();
    return '$salt:$h';
  }

  /// 校验连接密码（未设置密码时直接放行）
  bool verifyUserPassword(String deviceId, String pwd) {
    final user = users[deviceId];
    if (user == null || user.passwordHash.isEmpty) return true;
    final parts = user.passwordHash.split(':');
    if (parts.length != 2) return false;
    return sha256.convert(utf8.encode('${parts[0]}:$pwd')).toString() ==
        parts[1];
  }

  /// 重置连接密码：生成 6 位数字新密码，返回明文供管理页一次性展示；
  /// 在线手机端立即收到新密码并本地保存（pendingReset 标记下次连接生效）
  String? resetUserPassword(String deviceId) {
    final user = users[deviceId];
    if (user == null) return null;
    final pwd = List.generate(6, (_) => _rnd.nextInt(10)).join();
    user.passwordHash = _hashPassword(pwd);
    user.pendingReset = true;
    unawaited(_saveUsers());
    if (user.clientId != null) {
      _sendTo(user.clientId!, {'type': 'admin:pwd-reset', 'password': pwd});
    }
    AppLog.i('host', '重置连接密码: ${user.name} ($deviceId)');
    notifyListeners();
    return pwd;
  }

  /// 设置用户备注名称（管理页展示优先于设备名）
  void setUserRemark(String deviceId, String remark) {
    final user = users[deviceId];
    if (user == null) return;
    user.remark = remark.trim();
    unawaited(_saveUsers());
    notifyListeners();
  }

  /// 管理员移交：目标用户成为管理员（原管理员降级，电脑端管理页操作）
  void transferAdmin(String deviceId) {
    final target = users[deviceId];
    if (target == null || target.shareOnly) return;
    _grantAdmin(target);
    AppLog.i('host', '管理员已移交: ${target.name} ($deviceId)');
  }

  /// 确认管理员激活/移交申请（UI 弹窗确认后调用）
  void approveAdmin(String deviceId) {
    final user = users[deviceId];
    if (user == null) return;
    _grantAdmin(user);
    pendingAdminApproval = null;
    AppLog.i('host', '管理员确认: ${user.name} ($deviceId)');
  }

  void _grantAdmin(HostUser user) {
    for (final u in users.values) {
      u.isAdmin = false;
    }
    user.isAdmin = true;
    _bootAdminCode = null; // 首启码已生效，不再展示
    _grantedAdminDevices.add(user.deviceId);
    adminDeviceId = user.deviceId;
    unawaited(_saveAdminState());
    unawaited(_saveUsers());
    // 推送最新身份给所有在线客户端（原管理员手机端实时降级）
    for (final u in users.values.where((u) => u.online)) {
      _pushUserList(u.clientId!);
    }
    notifyListeners();
  }

  /// 拒绝管理员激活/移交申请：清除待确认；未确认的新激活设备踢出并移除
  void rejectAdmin(String deviceId) {
    final claim = pendingAdminApproval?['claim'] == true;
    pendingAdminApproval = null;
    final user = users[deviceId];
    if (user == null) return;
    if (claim) {
      _sendTo(user.clientId!, {
        'type': 'user:claim-result',
        'ok': false,
        'error': '管理员申请已被电脑端拒绝',
      });
    } else {
      if (user.clientId != null) _service.kickClient(user.clientId!);
      users.remove(deviceId);
      unawaited(_saveUsers());
    }
    notifyListeners();
  }

  /// 管理员共享文件夹：按设备 id / 公开（二维码）两种方式
  /// - deviceId 指定：直接共享给该设备用户
  /// - 两者皆空：公开共享（扫码即可加入）
  /// v5.9+ 去手机号：不再支持手机号指定共享
  ShareConfig? createShare({
    String? deviceId,
    required String folder,
    required List<String> perms,
    String remark = '',
  }) {
    // 路径必须是绝对路径且存在
    final dir = Directory(folder.replaceAll('/', Platform.pathSeparator));
    if (!dir.existsSync()) return null;

    // 设备指定或公开共享
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
        targetDeviceId: deviceId,
        remark: remark.trim());
    user?.shares.add(share);
    _shareTable[share.token] = share;
    AppLog.i('host', '创建共享: ${user?.name ?? '公开二维码'} -> $folder '
        'token=${share.token} perms=$perms${remark.trim().isNotEmpty ? ' 备注=${remark.trim()}' : ''}');
    notifyListeners();
    _persistShares();
    return share;
  }

  /// 修改共享备注名称（管理页操作，本地落盘 + 服务器同步）
  void setShareRemark(String token, String remark) {
    final share = _shareTable[token];
    if (share == null) return;
    share.remark = remark.trim();
    AppLog.i('host', '修改共享备注: ${share.name} token=$token 备注=${share.remark}');
    notifyListeners();
    _persistShares();
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
    _persistShares();
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
    _persistShares();
  }

  /// 已连接用户扫码附加共享（管理员扫自己的码/用户扫新码）
  bool attachShare(String clientId, String token) {
    final user = _userByClientId(clientId);
    final share = _shareTable[token];
    if (user == null || share == null) return false;
    if (!user.shares.any((s) => s.token == token)) {
      // 校验共享目标：共享给该设备或公开
      if (!_canBind(share, user.deviceId)) {
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
    // 重新连接时恢复持久化的管理员设备 id（进程内断开重连场景）
    await _loadAdminState();
    // 恢复激活码（重启不丢），并同步服务器
    await _loadActCodes();
    // 恢复用户列表（离线），手机端重新加入时更新在线状态
    await _loadUsers();
    // 恢复共享配置（重启不丢），并给已绑定用户补回 shares 列表
    await _loadShares();
    // 恢复最近 7 天传输记录（程序重启后仍可查看）
    await _loadTransfers();
    // 注册名使用本地备注（无备注时默认"电脑-桌面"）
    _service.deviceName = deviceName;
    await _service.connect(serverUrl);
  }

  /// 设备备注名（持久化，注册时上报给服务器，手机端选择连接时展示）
  String get deviceName {
    try {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final f = File('$base/p2p_desktop/device_name');
      if (f.existsSync()) {
        final name = f.readAsStringSync().trim();
        if (name.isNotEmpty) return name;
      }
    } catch (e) {
      AppLog.w('host', '读取设备备注名失败', e);
    }
    return '电脑-桌面';
  }

  /// 设置设备备注名：持久化并重连信令（立即生效，手机端下次连接可见）
  Future<void> setDeviceName(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean == deviceName) return;
    try {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dir = Directory('$base/p2p_desktop');
      dir.createSync(recursive: true);
      await File('${dir.path}/device_name').writeAsString(clean);
      AppLog.i('host', '设备备注名已保存: $clean');
    } catch (e) {
      AppLog.e('host', '保存设备备注名失败', e);
    }
    // 重连信令使新名称立即生效（在线手机端断开重连后也会看到新名称）
    if (serverUrl.isNotEmpty) {
      await disconnect();
      await connect(server: serverUrl);
    }
  }

  // ── 关闭窗口行为（v6.10） ──────────────────────────────
  // 与 C++ runner 层共享 %APPDATA%\p2p_desktop\close_action 记忆文件：
  // minimize=最小化到托盘 / quit=退出应用 / ask=每次询问（删除文件）
  String get closeAction {
    try {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final f = File('$base/p2p_desktop/close_action');
      if (f.existsSync()) {
        final v = f.readAsStringSync().trim();
        if (v == 'minimize' || v == 'quit') return v;
      }
    } catch (e) {
      AppLog.w('host', '读取关闭窗口行为失败', e);
    }
    return 'ask';
  }

  /// 设置关闭窗口行为：ask=每次询问（删除记忆）/ minimize=最小化到托盘 /
  /// quit=退出应用；与 C++ 层 WM_CLOSE 处理共用记忆文件
  Future<void> setCloseAction(String action) async {
    final clean = action.trim();
    if (clean != 'ask' && clean != 'minimize' && clean != 'quit') return;
    try {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dir = Directory('$base/p2p_desktop');
      dir.createSync(recursive: true);
      final f = File('${dir.path}/close_action');
      if (clean == 'ask') {
        if (f.existsSync()) f.deleteSync();
      } else {
        await f.writeAsString(clean);
      }
      AppLog.i('host', '关闭窗口行为已保存: $clean');
    } catch (e) {
      AppLog.e('host', '保存关闭窗口行为失败', e);
    }
  }

  Future<void> disconnect() async {
    await _service.dispose();
    state = HostState.idle;
    pairCode = '';
    users.clear();
    adminDeviceId = null;
    pendingAdminApproval = null;
    _shareTable.clear();
    _recvStates.clear();
    _sendingClients.clear();
    notifyListeners();
  }

  /// 是否在线（已注册/已连接，接受手机端连接）
  bool get isOnline =>
      state == HostState.registered || state == HostState.peerConnected;

  /// 在线/离线切换：
  /// - 离线：通知服务器删除会话（手机端立即收到“电脑离线”），停止信令且
  ///   不再自动重连；保留 users/shares/transfers 等本地数据（管理页仍可用）
  /// - 在线：重新注册（配对码按硬件 ID 持久化，不变）
  Future<void> setOnline(bool on) async {
    if (on == isOnline) return;
    if (on) {
      if (serverUrl.isEmpty) return;
      AppLog.i('host', '切换为在线，重新注册');
      await connect(server: serverUrl);
    } else {
      AppLog.i('host', '切换为离线，停止接受手机端连接');
      await _service.goOffline();
      state = HostState.offline;
      pairCode = '';
      // 仅清理传输态内存，保留 users/shares/transfers/激活码等本地数据
      _recvStates.clear();
      _sendingClients.clear();
      notifyListeners();
    }
  }

  // 传输中断清理：关闭该客户端的接收流（保留 .part 供续传）、复位发送状态
  Future<void> _cleanupBrokenTransfers(String clientId) async {
    AppLog.i('host', '清理中断传输（保留.part供续传）[$clientId]');
    // 断开/超时：该客户端的进行中传输记录标记失败，避免界面永久显示「正在发送」
    for (final t in transfers) {
      if (t.clientId == clientId && t.status == 'transferring') {
        t.finish('error', connType: connTypeRaw);
      }
    }
    unawaited(_saveTransfers());
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
    // v6.30+：优先 Known Folder 真实路径（识别 OneDrive/文件夹重定向），
    // 解析失败回退 USERPROFILE 硬拼，保证无重定向环境行为不变
    final real = resolveKnownFolders();
    if (real.isNotEmpty && !_kfPathLogged) {
      _kfPathLogged = true;
      AppLog.i('host', '特殊文件夹路径解析: '
          '${real.entries.map((e) => '${e.key}=${e.value}').join(' | ')}');
    }
    final specials = <String, String>{
      '桌面': real['desktop'] ?? '$profile\\Desktop',
      '文档': real['documents'] ?? '$profile\\Documents',
      '下载': real['downloads'] ?? '$profile\\Downloads',
      '图片': real['pictures'] ?? '$profile\\Pictures',
      '视频': real['videos'] ?? '$profile\\Videos',
      '音乐': real['music'] ?? '$profile\\Music',
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
          final name = e.path.split(Platform.pathSeparator).last;
          int s;
          try {
            // stat 不打开文件句柄，系统独占锁定的文件（hiberfil.sys 等）也能读大小
            s = (await e.stat()).size;
          } catch (_) {
            continue; // 仍失败的锁定文件跳过，不拖垮整个目录浏览
          }
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
      case 'user:power':
        _handleRemotePower(clientId, msg.data);
        break;
      case 'user:auto-login':
        _handleRemoteAutoLogin(clientId, msg.data);
        break;
      case 'user:create-code':
        _handleCreateActCode(clientId, msg.data);
        break;
      case 'user:revoke-code':
        _handleRevokeActCode(clientId, msg.data);
        break;
      case 'auth:verify':
        _handleAuthVerify(clientId, msg.data);
        break;
      case 'auth:change-pwd':
        _handleAuthChangePwd(clientId, msg.data);
        break;
      default:
        break;
    }
  }

  bool _isAdmin(String clientId) {
    final user = _userByClientId(clientId);
    if (user == null) return false;
    // v5.9+：管理员身份仅由「管理员码激活 + 电脑端确认」产生，无手机号识别/兜底
    return user.isAdmin;
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
  bool _isAdminRaw(HostUser user) => user.isAdmin;

  Future<void> _sendTo(String clientId, Map<String, dynamic> json) async {
    await _service.sendJsonTo(clientId, json);
  }

  // ── 用户管理消息 ────────────────────────────────────────
  void _handleUserList(String clientId) {
    final admin = _isAdmin(clientId);
    final me = _userByClientId(clientId);
    // v5.9+：管理员设备 id 告知手机端（手机端可提示“更换管理员”由电脑端确认）
    _sendTo(clientId, {
      'type': 'user:list-result',
      // 非管理员（含共享访客）只返回自己条目，避免暴露其他用户信息
      'users': admin
          ? users.values.map((u) => u.toJson()).toList()
          : (me != null ? [me.toJson()] : <dynamic>[]),
      'myDeviceId': me?.deviceId ?? '',
      'isAdmin': admin,
      'adminDeviceId': admin ? null : adminDeviceId,
      // 管理员额外返回全部共享配置（共享文件夹管理页）
      if (admin)
        'shares': _shareTable.values.map((s) => s.toJson()).toList(),
    });
  }

  /// 更换管理员：正式用户申请成为本电脑端管理员（电脑端弹窗确认后生效）
  void _handleClaimAdmin(String clientId) {
    final user = _userByClientId(clientId);
    if (user == null || user.shareOnly) {
      _sendTo(clientId, {
        'type': 'user:claim-result',
        'ok': false,
        'error': '仅正式用户可申请成为管理员',
      });
      return;
    }
    if (user.isAdmin) {
      _sendTo(clientId, {'type': 'user:claim-result', 'ok': true});
      return;
    }
    if (pendingAdminApproval != null) {
      _sendTo(clientId, {
        'type': 'user:claim-result',
        'ok': false,
        'error': '已有待确认的申请，请稍后再试',
      });
      return;
    }
    pendingAdminApproval = {
      'deviceId': user.deviceId,
      'name': user.name,
      'claim': true,
    };
    AppLog.i('host', '管理员更换申请待确认: ${user.name} (${user.deviceId})');
    notifyListeners();
  }

  /// 远程电源控制（v6.2）：仅管理员可执行；关机/重启延迟 15 秒执行，
  /// 期间手机端可发送 cancel（shutdown /a）中止；先回执再等待进程退出校验
  Future<void> _handleRemotePower(
      String clientId, Map<String, dynamic> msg) async {
    final user = _userByClientId(clientId);
    if (user == null || !user.isAdmin) {
      _sendTo(clientId, {
        'type': 'user:power-result',
        'ok': false,
        'error': '仅管理员可执行电源控制',
      });
      return;
    }
    final action = msg['action']?.toString() ?? '';
    switch (action) {
      case 'shutdown':
      case 'reboot':
        try {
          final p = await Process.start('shutdown', [
            action == 'shutdown' ? '/s' : '/r',
            '/t',
            '15',
          ]);
          // 先回执：手机端进入 15 秒取消窗口
          _sendTo(clientId, {
            'type': 'user:power-result',
            'ok': true,
            'action': action,
            'delaySeconds': 15,
          });
          AppLog.i('host',
              '远程${action == 'shutdown' ? '关机' : '重启'}已受理 (15s后执行)');
          final code = await p.exitCode;
          if (code != 0) {
            AppLog.w('host', '远程电源执行异常退出: code=$code');
            _sendTo(clientId, {
              'type': 'user:power-result',
              'ok': false,
              'error': '执行失败（退出码 $code），可能权限不足',
            });
          }
        } catch (e) {
          AppLog.w('host', '远程电源执行异常: $e');
          _sendTo(clientId, {
            'type': 'user:power-result',
            'ok': false,
            'error': '执行失败: $e',
          });
        }
        break;
      case 'cancel':
        // 取消挂起的关机/重启（无挂起时 shutdown /a 退出码非 0，无需提示）
        try {
          await Process.run('shutdown', ['/a']);
          _sendTo(clientId, {
            'type': 'user:power-result',
            'ok': true,
            'action': 'cancel',
          });
          AppLog.i('host', '远程电源操作已取消');
        } catch (e) {
          AppLog.w('host', '远程电源取消失败: $e');
          _sendTo(clientId, {
            'type': 'user:power-result',
            'ok': false,
            'error': '取消失败: $e',
          });
        }
        break;
      default:
        _sendTo(clientId, {
          'type': 'user:power-result',
          'ok': false,
          'error': '未知电源操作: $action',
        });
    }
  }

  /// 远程自动登录设置（v6.6）：仅管理员可操作；写 HKLM 需管理员权限，
  /// 电脑端须以管理员身份运行（已提权直接写，无 UAC 弹窗）；
  /// 密码仅在本机注册表落盘，不经日志；旧版电脑端静默忽略此消息
  Future<void> _handleRemoteAutoLogin(
      String clientId, Map<String, dynamic> msg) async {
    final user = _userByClientId(clientId);
    if (user == null || !user.isAdmin) {
      _sendTo(clientId, {
        'type': 'user:auto-login-result',
        'ok': false,
        'error': '仅管理员可设置自动登录',
      });
      return;
    }
    final action = msg['action']?.toString() ?? '';
    try {
      switch (action) {
        case 'status':
          _sendTo(clientId, {
            'type': 'user:auto-login-result',
            'ok': true,
            'enabled': await AutoLoginService.isEnabled(),
            'elevated': await AutoLoginService.isElevated(),
          });
          break;
        case 'enable':
          if (!await AutoLoginService.isElevated()) {
            _sendTo(clientId, {
              'type': 'user:auto-login-result',
              'ok': false,
              'error': '电脑端未以管理员身份运行，请在电脑上右键本程序选择'
                  '“以管理员身份运行”后重试',
            });
            return;
          }
          final pwd = msg['password']?.toString() ?? '';
          if (pwd.isEmpty) {
            _sendTo(clientId, {
              'type': 'user:auto-login-result',
              'ok': false,
              'error': '密码不能为空',
            });
            return;
          }
          final ok = await AutoLoginService.enable(pwd);
          _sendTo(clientId, {
            'type': 'user:auto-login-result',
            'ok': ok,
            'enabled': ok,
            'error': ok ? null : '注册表写入失败，请检查电脑端权限',
          });
          if (ok) AppLog.i('host', '远程自动登录已开启（发送者 $user.name）');
          break;
        case 'disable':
          if (!await AutoLoginService.isElevated()) {
            _sendTo(clientId, {
              'type': 'user:auto-login-result',
              'ok': false,
              'error': '电脑端未以管理员身份运行，请在电脑上右键本程序选择'
                  '“以管理员身份运行”后重试',
            });
            return;
          }
          final ok = await AutoLoginService.disable();
          _sendTo(clientId, {
            'type': 'user:auto-login-result',
            'ok': ok,
            'enabled': false,
            'error': ok ? null : '注册表清理失败，请检查电脑端权限',
          });
          if (ok) AppLog.i('host', '远程自动登录已关闭（发送者 $user.name）');
          break;
        default:
          _sendTo(clientId, {
            'type': 'user:auto-login-result',
            'ok': false,
            'error': '未知操作: $action',
          });
      }
    } catch (e) {
      AppLog.w('host', '远程自动登录处理异常: $e');
      _sendTo(clientId, {
        'type': 'user:auto-login-result',
        'ok': false,
        'error': '执行异常: $e',
      });
    }
  }

  /// 手机端远程生成激活码（v5.9+：管理员 App 内发码，无需到电脑前）
  void _handleCreateActCode(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) {
      _sendTo(clientId, {
        'type': 'user:code-result',
        'ok': false,
        'error': '仅管理员可生成激活码',
      });
      return;
    }
    // v6.14+ 身份二态化：仅生成管理员码（手机端消息的 admin 字段不再区分）
    final code = generateActCode();
    _sendTo(clientId, {'type': 'user:code-result', 'ok': true, 'code': code});
  }

  /// 手机端远程撤销激活码
  void _handleRevokeActCode(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) {
      _sendTo(clientId, {
        'type': 'user:code-result',
        'ok': false,
        'error': '仅管理员可撤销激活码',
      });
      return;
    }
    final code = msg['code']?.toString() ?? '';
    if (!_actCodes.containsKey(code)) {
      _sendTo(clientId, {
        'type': 'user:code-result',
        'ok': false,
        'error': '激活码不存在或已使用',
      });
      return;
    }
    revokeActCode(code);
    _sendTo(clientId, {'type': 'user:code-result', 'ok': true});
  }

  /// 数据通道连接密码校验（v5.9+；服务器全程不接触密码）
  void _handleAuthVerify(String clientId, Map<String, dynamic> msg) {
    final user = _userByClientId(clientId);
    if (user == null) return;
    final pwd = msg['password']?.toString() ?? '';
    if (verifyUserPassword(user.deviceId, pwd)) {
      user.pendingReset = false;
      unawaited(_saveUsers());
      _sendTo(clientId, {'type': 'auth:ok'});
    } else {
      AppLog.w('host', '连接密码校验失败: ${user.name} (${user.deviceId})');
      _sendTo(clientId, {
        'type': 'auth:denied',
        'error': user.pendingReset
            ? '连接密码已被管理员重置，请获取新密码'
            : '连接密码错误',
      });
      // 稍等片刻让对方收到错误提示后断开
      Future.delayed(const Duration(milliseconds: 500), () {
        _service.kickClient(clientId);
      });
    }
  }

  /// 手机端主动修改连接密码（管理员可自行更换，同步到电脑端）
  void _handleAuthChangePwd(String clientId, Map<String, dynamic> msg) {
    final user = _userByClientId(clientId);
    if (user == null) return;
    final oldPwd = msg['oldPassword']?.toString() ?? '';
    final newPwd = msg['newPassword']?.toString() ?? '';
    if (newPwd.length < 6 || newPwd.length > 16) {
      _sendTo(clientId, {
        'type': 'auth:pwd-result',
        'ok': false,
        'error': '新密码需 6-16 位',
      });
      return;
    }
    if (!verifyUserPassword(user.deviceId, oldPwd)) {
      _sendTo(clientId, {
        'type': 'auth:pwd-result',
        'ok': false,
        'error': '原密码错误',
      });
      return;
    }
    user.passwordHash = _hashPassword(newPwd);
    user.pendingReset = false;
    unawaited(_saveUsers());
    AppLog.i('host', '连接密码已修改: ${user.name} (${user.deviceId})');
    _sendTo(clientId, {'type': 'auth:pwd-result', 'ok': true});
  }

  void _handleCreateShare(String clientId, Map<String, dynamic> msg) {
    if (!_isAdmin(clientId)) {
      _sendTo(clientId,
          {'type': 'user:share-result', 'ok': false, 'error': '仅管理员可执行此操作'});
      return;
    }
    final deviceId = msg['deviceId']?.toString() ?? '';
    final folder = msg['folder']?.toString() ?? '';
    final perms = (msg['perms'] as List? ?? [])
        .map((e) => e.toString())
        .where((e) => ['download', 'upload', 'delete'].contains(e))
        .toList();
    final share = createShare(
      deviceId: deviceId.isEmpty ? null : deviceId,
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
            int size;
            try {
              // stat 不打开文件句柄，系统独占锁定的文件（hiberfil.sys 等）也能读大小
              size = (await e.stat()).size;
            } catch (_) {
              continue; // 仍失败的锁定文件跳过，不拖垮整个目录浏览
            }
            list.add(FileEntry(
                    name: name,
                    type: 'file',
                    size: size,
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
          int size;
          try {
            // stat 不打开文件句柄，系统独占锁定的文件（hiberfil.sys 等）也能读大小
            size = (await e.stat()).size;
          } catch (_) {
            continue; // 仍失败的锁定文件跳过，不拖垮整个目录浏览
          }
          list.add(FileEntry(
                  name: name,
                  type: 'file',
                  size: size,
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
      t.finish('done', connType: connTypeRaw);
      unawaited(_saveTransfers());
      AppLog.i('download', '发送完成: $fileName (${t.transferred}/${size}B) [$clientId]');
      notifyListeners();
    } catch (e) {
      AppLog.e('download',
          '发送异常: ${msg['fileName']} 已发送=$sentBytes B', e);
      // 发送中止/异常：进行中的记录标记失败并落盘，避免重启后残留「正在发送」
      for (final t in transfers) {
        if (t.clientId == clientId && t.status == 'transferring') {
          t.finish('error', connType: connTypeRaw);
        }
      }
      unawaited(_saveTransfers());
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
      if (item != null) {
        item.finish('error', connType: connTypeRaw);
      }
      unawaited(_saveTransfers());
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
        item.finish(ok ? 'done' : 'error', connType: connTypeRaw);
      }
      unawaited(_saveTransfers());
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
    // 传输记录仅保留 7 天：新增记录时清理过期记录（运行期间累积的旧记录自动消失，
    // 避免列表无限增长）
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _transferRetentionDays));
    transfers.removeWhere((x) => x.startTime.isBefore(cutoff));
    final user = _userByClientId(clientId);
    final t = TransferItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      fileName: name,
      direction: direction,
      total: total,
      startTime: DateTime.now(),
      clientName: user?.name ?? '手机',
      clientId: clientId,
      // 创建时快照连接方式（历史记录显示固定，不再随实时连接变化）
      connType: connTypeRaw,
    );
    transfers.add(t);
    unawaited(_saveTransfers());
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
