import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_log.dart';
import 'auth_service.dart';
import 'models.dart';
import 'protocol.dart';
import 'rtc_service.dart';
import 'signaling_service.dart';
import 'update_check.dart';
import 'video_play_service.dart';

/// 连接状态
enum ConnectState { idle, connecting, paired, peerConnected, error, lost }

/// 上传文件名冲突（等待用户决策）
class UploadConflict {
  final String fileName;
  final String requestId;

  const UploadConflict({required this.fileName, required this.requestId});
}

/// 下载完成信息（UI 弹出"打开/保存到手机/分享"操作面板）
class DownloadDoneInfo {
  final String path;
  final String name;

  const DownloadDoneInfo({required this.path, required this.name});
}

/// 断点续传记录：上传
class ResumeUpload {
  final String requestId;
  final String fileName;
  final String localPath;
  final int offset; // 已发送字节（握手后以电脑端 accept.offset 为准）
  final String subPath; // 上传目标目录
  final String? shareToken; // 共享目录码（非空=上传到共享目录）
  int attempts; // 已尝试次数（超过上限丢弃，避免死循环）

  ResumeUpload({
    required this.requestId,
    required this.fileName,
    required this.localPath,
    required this.offset,
    required this.subPath,
    this.shareToken,
    this.attempts = 0,
  });
}

/// 断点续传记录：下载
class ResumeDownload {
  final String path; // 电脑端文件路径
  final String fileName;
  final int offset; // 已接收字节
  final String? shareToken; // 共享目录码（非空=从共享目录下载）

  const ResumeDownload({
    required this.path,
    required this.fileName,
    required this.offset,
    this.shareToken,
  });
}

/// 一次成功配对的历史记录（启动时选择连接 / 自动直连用）
class PairInfo {
  final String server;
  final String code;

  /// 显示名（电脑："电脑 XXXX"；共享：共享文件夹名）
  final String? name;

  /// 最近连接时间（历史列表排序）
  final DateTime? lastAt;

  /// 非空 = 共享文件夹记录（仅列表手动选择，不参与启动自动直连）
  final String? shareToken;

  const PairInfo({
    required this.server,
    required this.code,
    this.name,
    this.lastAt,
    this.shareToken,
  });

  /// 是否为共享文件夹记录
  bool get isShare => shareToken != null && shareToken!.isNotEmpty;

  factory PairInfo.fromJson(Map<String, dynamic> json) => PairInfo(
        server: json['server'] as String? ?? '',
        code: json['code'] as String? ?? '',
        name: json['name']?.toString(),
        lastAt: DateTime.tryParse(json['lastAt']?.toString() ?? ''),
        shareToken: json['shareToken']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'server': server,
        'code': code,
        if (name != null) 'name': name,
        if (lastAt != null) 'lastAt': lastAt!.toIso8601String(),
        if (shareToken != null && shareToken!.isNotEmpty)
          'shareToken': shareToken,
      };
}

/// 电脑端已有其他管理员时的更换确认请求（UI 弹窗展示）
class AdminClaimRequest {
  /// 现任管理员展示名（备注优先，无则设备名）
  final String adminName;

  const AdminClaimRequest({required this.adminName});
}

/// 远程电源控制回执提示（v5.9）：成功执行后延迟秒数内可取消
class PowerNotice {
  /// 提示文案（如“已执行：电脑将在 15 秒后关机”）
  final String text;

  /// 展示时长（秒）；执行类操作同时是取消窗口期
  final int delaySeconds;

  const PowerNotice({required this.text, required this.delaySeconds});
}

/// 电脑端升级提示（v5.42+）：管理员手机端收到服务器推送后展示横幅，
/// 确认后服务器通知电脑端静默升级；status 区分提示/已通知/失败三态
class DesktopUpgradeInfo {
  /// 电脑端当前版本
  final String current;

  /// 最新版本
  final String latest;

  /// 是否重要升级
  final bool urgent;

  /// 电脑端名称
  final String hostName;

  /// 状态：notify=提示中 / confirmed=已通知升级 / failed=升级失败
  final String status;

  /// 失败原因（status=failed 时有值）
  final String? error;

  const DesktopUpgradeInfo({
    required this.current,
    required this.latest,
    this.urgent = false,
    this.hostName = '电脑',
    this.status = 'notify',
    this.error,
  });
}

/// 全局控制器：编排信令、WebRTC 数据通道与文件传输
class AppController extends ChangeNotifier {
  final SignalingService _signaling = SignalingService();
  final RtcService _rtc = RtcService();

  // ── 连接状态 ──────────────────────────────────────────
  ConnectState state = ConnectState.idle;
  String? errorMessage;
  String? hostName;

  /// 连接建立时间（连接方式探测超时兑底文案用）
  DateTime? _connectedAt;

  /// v5.6+ 强制升级：服务器拒绝旧版（APP_VERSION_REQUIRED）时回调，
  /// 由 UI 层（_AuthGate）弹出不可跳过的强制升级窗
  void Function()? onVersionRequired;

  /// 自动直连模式（App 冷启动自动配对）：连接失败自动重试，不弹错误死局；
  /// 手动扫码/输入配对时置 false，失败立即提示
  bool autoMode = false;

  /// 当前连接方式：直连 / 服务器中转 / 未知（由 RtcService 探测）
  String get connectionType => _rtc.connectionType;

  /// 连接方式的用户可读标签（用于 UI 展示）
  String get connTypeLabel => switch (_rtc.connectionType) {
        'relay' => '服务器中转',
        'direct' => 'P2P直连',
        _ => _unknownConnLabel,
      };

  /// 连接方式未知时的兑底文案：连接建立后 3 秒内为真实探测窗口显示
  /// “探测中…”，超时仍未探测出则显示中性“已连接”，避免一直停在“探测中…”
  /// （部分设备 getStats 不返回选中标记，探测可能永久不完成）
  String get _unknownConnLabel {
    final t = _connectedAt;
    if (t == null) return '探测中…';
    return DateTime.now().difference(t).inSeconds < 3 ? '探测中…' : '已连接';
  }

  // ── 浏览状态 ──────────────────────────────────────────
  final List<String> _path = []; // 面包屑名称栈
  final List<String> _dirStack = []; // 每层目录的完整路径栈（支持我的电脑模式）
  List<FileEntry> files = [];
  bool listLoading = false;
  String? listError;
  String dirPath = '';

  // ── 多用户与共享目录 ──────────────────────────────────
  String deviceId = ''; // 设备唯一标识（持久化，多用户身份）
  bool isAdmin = false; // 是否为该电脑端管理员
  bool isShareGuest = false; // 共享访客（扫码共享连接）：仅可访问分享的共享目录

  // ── 电脑端升级提示（v5.42+）────────────────────────────
  DesktopUpgradeInfo? _desktopUpgrade;
  DesktopUpgradeInfo? get desktopUpgrade => _desktopUpgrade;
  AdminClaimRequest? _adminClaimRequest; // 已有其他管理员：更换确认请求
  bool _adminClaimDismissed = false; // 本会话已拒绝更换，不再重复弹窗
  AdminClaimRequest? get adminClaimRequest => _adminClaimRequest;

  // ── 连接密码（v5.4+） ──────────────────────────────────
  /// 连接密码校验失败信息（触发主页密码输入弹窗；消费后置空）
  String? _authError;
  String? get authError => _authError;
  static const _pwdKeyPrefix = 'conn_pwd_'; // 密码按配对码持久化
  final List<ShareEntry> shares = []; // 已加入的共享目录
  final List<ShareEntry> allShares = []; // 管理员：电脑端全部共享配置
  List<Map<String, dynamic>> users = []; // 用户列表（管理员可见）
  String? _pendingShareToken; // 本次连接携带的共享码
  bool _shareConnectMode = false; // 免配对码共享连接（v4.8+：共享中心页）
  ShareEntry? _lastShareResult; // 最近一次共享操作结果（UI 展示二维码）

  // 共享目录浏览状态
  ShareEntry? activeShare; // 当前浏览的共享（null=主目录）
  String sharePath = ''; // 共享文件夹内相对路径
  final List<String> shareCrumbs = []; // 共享面包屑
  List<FileEntry> shareFiles = [];
  bool shareLoading = false;
  String? shareError;

  // 管理员目录选择器（共享文件夹选择）
  List<FileEntry> pickFiles = [];
  String pickPath = '';
  final List<String> pickCrumbs = [];
  bool pickLoading = false;

  // 用户操作结果提示（SnackBar 展示后清空）
  String? actionMessage;
  ShareEntry? _activeUploadShare; // 当前上传批次的目标共享（断线续传定位）

  // ── 传输状态 ──────────────────────────────────────────
  final List<TransferItem> transfers = [];
  String? activeDownloadName;
  int activeDownloadSize = 0;
  int activeDownloadBytes = 0;
  /// 最近一次下载完成信息（UI 消费后置空）
  DownloadDoneInfo? _lastDownloadDone;
  // ── 上传目标目录与冲突决策 ─────────────────────────────
  String uploadDirPath = ''; // 相对共享目录，空=根目录
  // 启动竞态：数据通道状态回调可能早于 channel 赋值/真正打开，期间发送
  // 会被静默丢弃（曾实测 upload-check 丢失、上传目录校验悬空），挂起补发
  bool _pendingUploadCheck = false;
  // 文件列表请求同源竞态：通道未就绪时被忽略，打开后补发
  bool _pendingBrowseList = false;
  // user:list 同源竞态：ICE connected 与 channel OPEN 会各触发一次状态
  // 事件，第一次时 isOpen 可能仍为 false，user:list 曾静默丢失
  // （管理员身份 isAdmin 永不更新 → 共享文件夹管理入口不显示），挂起补发
  bool _pendingUserInfo = false;
  String? _desktopPath; // 电脑端桌面路径（默认上传目录）
  String? _rememberedUploadDir; // 上次使用的上传目录（持久化）
  static const _prefUploadDir = 'last_upload_dir';
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
  Timer? _recvTimeoutTimer; // 下载接收超时兜底（30s 无数据判定通道失效）
  int _lastDownloadNotifyMs = 0; // 下载进度 UI 刷新节流（高速直连时防主线程拥堵）
  Timer? _recvStatsTimer; // 下载期间周期上报写盘消费进度（电脑端自适应流控）
  // 写盘合并缓冲：64KB 小块先积攒到 1MB 再一次性写入，避免频繁小写盘
  // （IOSink 内部缓冲仅 8KB，逐块 add 会把 64KB 拆成 8 次 8KB 写盘调用，
  // 写盘频率是接收侧消费瓶颈——实测直连 8MB/s 时已接近上限 ~9.8MB/s）
  final BytesBuilder _recvBuf = BytesBuilder(copy: false);
  int _recvBufBytes = 0;
  static const int _recvFlushSize = 1024 * 1024; // 1MB 合并阈值

  // 在线播放状态
  bool _playMode = false; // 当前下载是否用于在线播放
  File? _playFile; // 播放临时文件（边下边播）
  final VideoPlayServer _playServer = VideoPlayServer();
  String? playUrl; // 本地播放地址，null=未就绪
  bool playFinished = false; // 视频已全部下载完成
  String? playError; // 播放/下载错误信息

  // 内部上传状态
  bool uploading = false;
  /// 当前正在上传的文件（v5.25+ 全局进度状态，供 UploadBanner 显示）
  String? activeUploadName;
  int activeUploadSize = 0;
  int activeUploadBytes = 0;
  bool _uploadCancelled = false; // 用户手动停止上传（批次级标志）
  int _uploadBytes = 0;
  int _uploadStartMs = 0;
  int _lastUploadLogBytes = 0; // 上传进度日志节流（每 8MB 记一次）
  int _lastDownloadLogBytes = 0; // 下载进度日志节流

  // ── 自动重连与断点续传 ──────────────────────────────────
  String? _lastServer; // 最近一次连接的服务器（自动重连用）
  String? _lastCode; // 最近一次配对码
  bool _manualDisconnect = false; // 用户主动断开：不再自动重连
  Timer? _reconnectTimer;
  Timer? _connectTimer; // 连接超时兜底（避免无限“正在连接”）
  int _reconnectAttempts = 0;
  final List<ResumeUpload> _resumeUploads = []; // 断线时中断的上传队列
  ResumeDownload? _resumeDownload; // 断线时中断的下载
  bool _resuming = false; // 防止重连恢复逻辑重复执行
  int _acceptOffset = 0; // 电脑端 accept 回包的实际续传起点

  // ── 初始化 ────────────────────────────────────────────
  AppController() {
    _loadTransfers();
    _loadRememberedUploadDir();
    _initDeviceId();
    _rtc.sendSignal = _signaling.sendSignal;
    // 连接方式探测完成：及时刷新 UI（直连/服务器中转徽标），
    // 否则探测结果要等下次其他刷新事件才能显示（如下拉刷新）
    _rtc.onConnectionType = (_) => notifyListeners();
    _signaling.onJoined = _onJoined;
    _signaling.onError = (reason) {
      AppLog.i('signal', '配对错误: $reason (autoMode=$autoMode, manual=$_manualDisconnect)');
      // v5.6+ 强制升级：旧版被服务器拒绝连接，通知 UI 弹强制升级窗
      if (reason == 'APP_VERSION_REQUIRED') {
        state = ConnectState.error;
        errorMessage = '当前版本已停止服务，请升级后重试';
        notifyListeners();
        onVersionRequired?.call();
        return;
      }
      // 配对码有效但电脑端未上线（host-offline）且处于自动直连模式：
      // 不报错，转入自动重试循环，等电脑端重新注册后自动恢复
      if (reason == 'host-offline' && !_manualDisconnect && autoMode) {
        if (state == ConnectState.lost) return; // 已在重试中（循环内 join 失败会重复触发）
        state = ConnectState.lost;
        errorMessage = '电脑端未在线，正在自动重连…';
        notifyListeners();
        _startAutoReconnect();
        return;
      }
      // 配对码无效（内部标识被电脑端重新生成）：保留本地配对信息不删除，
      // 连接页提示重新激活；下次启动自动直连仍会用旧码尝试一次，
      // 失败后再次给出激活引导（避免误删后连接页空白、用户不知如何重连）
      state = ConnectState.error;
      errorMessage = reason == 'host-offline'
          ? '电脑端未在线，请确认电脑端已启动后重试'
          : reason == '配对码无效'
              ? '配对码无效或已变更，请重新激活或联系电脑端管理员'
              : reason;
      notifyListeners();
    };
    _signaling.onSignal = (signal) => _rtc.handleSignal(signal);
    _signaling.onConnectError = (msg) {
      AppLog.i('signal', '服务器连接失败: $msg (autoMode=$autoMode)');
      // 自动直连/自动重连场景：网络抖动不报错，转入重试循环
      if (!_manualDisconnect && autoMode) {
        if (state == ConnectState.lost) return;
        state = ConnectState.lost;
        errorMessage = '无法连接服务器，正在自动重试…';
        notifyListeners();
        _startAutoReconnect();
        return;
      }
      state = ConnectState.error;
      errorMessage = '无法连接服务器: $msg';
      notifyListeners();
    };
    _signaling.onPeerDisconnected = _onPeerLost;
    _signaling.onDesktopUpgradeNotify = _onDesktopUpgradeNotify;
    _signaling.onDesktopUpgradeResult = _onDesktopUpgradeResult;
    _rtc.messages.listen(_onChannelMessage);
    _rtc.stateChanges.listen((open) {
      AppLog.i('rtc', '数据通道状态变化: ${open ? 'OPEN' : 'CLOSED'} (当前state=$state)');
      // 通道真正可用后补发被启动竞态丢弃的请求（open 事件可能早于 channel 赋值）
      if (open && _rtc.isOpen) {
        if (_pendingUploadCheck) _checkRememberedUploadDir();
        if (_pendingBrowseList) _requestFileList();
        if (_pendingUserInfo) _requestUserInfo();
      }
      if (open && state != ConnectState.peerConnected) {
        _connectedAt = DateTime.now();
        state = ConnectState.peerConnected;
        notifyListeners();
        _requestFileList();
        _requestUserInfo();
        _checkRememberedUploadDir();
        // 连接密码自动校验（v5.4+）：本地保存过密码则自动验证，未设置则不校验
        _maybeAuthVerify();
        // 自动重连成功（数据通道恢复）：续传断线时中断的传输
        _resumePendingTransfers();
      } else if (!open && state == ConnectState.peerConnected) {
        _onPeerLost();
      }
    });
    AppLog.i('app', 'AppController 初始化完成');
  }

  /// 生成并持久化设备唯一标识（多用户身份，重新安装后变化）
  Future<void> _initDeviceId() async {
    try {
      final p = await SharedPreferences.getInstance();
      deviceId = p.getString('device_id') ?? '';
      if (deviceId.isEmpty) {
        final r = Random();
        deviceId = 'D${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
            '${r.nextInt(0xFFFFFF).toRadixString(36)}';
        await p.setString('device_id', deviceId);
        AppLog.i('app', '已生成设备标识: $deviceId');
      } else {
        AppLog.i('app', '设备标识: $deviceId');
      }
    } catch (e) {
      deviceId = 'D${DateTime.now().microsecondsSinceEpoch}';
      AppLog.w('app', '生成设备标识失败，使用临时标识', e);
    }
  }

  // ── 连接流程 ──────────────────────────────────────────
  /// 最近连接的服务器地址（扫码共享码时判断是否同一电脑）
  String? get lastServerUrl => _lastServer;

  /// 最近连接的配对码
  String? get lastPairCode => _lastCode;

  Future<void> connect(String serverUrl, String pairCode,
      {String? shareToken, bool joinByShare = false}) async {
    _lastServer = serverUrl.replaceAll(RegExp(r'/$'), '');
    _lastCode = pairCode.trim();
    _pendingShareToken = shareToken;
    _shareConnectMode = joinByShare;
    // 共享访客标记：扫码/免配对码共享连接不保存配对信息、界面只开放共享功能
    isShareGuest = shareToken != null && shareToken.isNotEmpty;
    _manualDisconnect = false;
    // 新会话：重置“拒绝更换管理员”抑制标志（断开重连后重新提示）
    _adminClaimDismissed = false;
    AppLog.i('connect', '发起连接: server=$_lastServer code=$_lastCode'
        '${joinByShare ? ' joinByShare' : ''}'
        '${shareToken != null ? ' share=$shareToken' : ''}');
    state = ConnectState.connecting;
    errorMessage = null;
    notifyListeners();

    // 连接超时兜底：服务器握手/join 无响应时不再无限“正在连接”。
    // 覆盖 connecting 与 paired：paired 表示已收到 joined 但电脑端 offer 未到
    // （电脑端刚上线补发 joined 时 offer 可能丢失），同样转入自动重连恢复
    _connectTimer?.cancel();
    _connectTimer = Timer(const Duration(seconds: 15), () {
      if (_manualDisconnect) return;
      final st = state;
      if (st != ConnectState.connecting && st != ConnectState.paired) return;
      if (autoMode) {
        // 自动直连：转入自动重试（进入主页面显示重连视图，电脑端上线自动恢复）
        state = ConnectState.lost;
        errorMessage = '连接超时，正在自动重连…';
        notifyListeners();
        _startAutoReconnect();
      } else {
        state = ConnectState.error;
        errorMessage = '连接超时，请检查网络后重试';
        AppLog.i('connect', '连接超时兜底(15s)触发');
        notifyListeners();
      }
    });

    try {
      await _rtc.init();
      await _signaling.connect(
        serverUrl: _lastServer!,
        pairCode: _lastCode!,
        deviceName: 'Android',
        deviceId: deviceId,
        shareToken: _pendingShareToken,
        activationCode: AuthService.instance.activationCode,
        // v5.12+：免配对码共享连接（join-by-share）必须携带设备令牌，
        // 服务器凭 actDevices 校验；此前未传导致列表点击连接恒被拒
        deviceToken: AuthService.instance.deviceToken,
        joinByShare: _shareConnectMode,
      );
    } catch (e) {
      if (autoMode && !_manualDisconnect) {
        // 自动直连：初始化失败同样转入自动重试
        state = ConnectState.lost;
        errorMessage = '初始化失败，正在自动重连…';
        notifyListeners();
        _startAutoReconnect();
      } else {
        state = ConnectState.error;
        errorMessage = '初始化失败: $e';
        notifyListeners();
      }
    }
  }

  void _onJoined(Map<String, dynamic> data) {
    // v5.19+：共享连接且未激活 → 本地保存共享访客身份（type='guest'，
    // 纯本地标记，无设备令牌）；之后「共享给我的」列表可免令牌重连
    // （服务器凭 join-relations 绑定放行）、重启不丢身份
    if (_pendingShareToken != null &&
        _pendingShareToken!.isNotEmpty &&
        !AuthService.instance.activated) {
      AppLog.i('auth', '共享连接成功，保存共享访客身份');
      unawaited(AuthService.instance.save(
        deviceToken: '',
        pairCode: _lastCode ?? '',
        type: 'guest',
        shareToken: _pendingShareToken ?? '',
      ));
      isShareGuest = true;
      notifyListeners();
    }
    // 服务器下发的 TURN 中继凭证（直连失败时的兜底通道）
    final turn = data['turn'];
    _rtc.turnConfig = turn is Map
        ? Map<String, dynamic>.from(turn)
        : null;
    final hostInfo = data['hostInfo'];
    hostName = hostInfo is Map
        ? hostInfo['name']?.toString() ?? '电脑'
        : data['name']?.toString() ?? '电脑';
    // 默认上传目录：优先恢复上次使用的目录；不存在时回退电脑桌面
    final desktop = hostInfo is Map ? hostInfo['desktop']?.toString() : null;
    if (desktop != null && desktop.isNotEmpty) {
      _desktopPath ??= desktop;
    }
    if (uploadDirPath.isEmpty) {
      uploadDirPath = (_rememberedUploadDir?.isNotEmpty ?? false)
          ? _rememberedUploadDir!
          : (_desktopPath ?? '');
      AppLog.i('upload', '默认上传目录: $uploadDirPath');
    }
    AppLog.i('connect', '配对成功: 主机=$hostName, TURN=${turn == null ? '未配置' : '已下发'}');
    state = ConnectState.paired;
    notifyListeners();
    // 配对成功即自动保存配对信息：主页作为入口后不再经过连接页的保存逻辑，
    // 统一在 controller 保存（手动连接/自动直连适用），
    // 保证下次启动能自动直连；
    // 共享访客（扫码共享连接）不保存：避免下次启动自动直连而成为配对客户端
    // （可能被误判为首个管理员）
    final srv = _lastServer;
    final code = _lastCode;
    if (srv != null && code != null && _pendingShareToken == null) {
      // 保存电脑端备注名，手机端选择连接时展示
      savePairInfo(srv, code,
          name: (hostName != null && hostName != '电脑')
              ? hostName
              : null);
    }
  }

  void _onPeerLost() {
    AppLog.i('connect', '对端断开触发 (state=$state, manual=$_manualDisconnect)');
    // lost 状态说明已在自动重连中（信令/RTC 重建会再次触发断开回调），不再重复处理
    if (state == ConnectState.idle || state == ConnectState.lost) return;
    _connectedAt = null;
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

  // ── 电脑端升级提示（v5.42+）──────────────────────────
  /// 服务器推送电脑端升级提示：仅管理员手机端收到。
  /// 电脑端已是最新（推送时点过后已升级）则清除提示
  void _onDesktopUpgradeNotify(Map<String, dynamic> info) {
    final latest = info['latest']?.toString() ?? '';
    final current = info['current']?.toString() ?? '';
    if (latest.isEmpty || current.isEmpty) return;
    if (_verNum(current) >= _verNum(latest)) {
      if (_desktopUpgrade != null) {
        AppLog.i('upgrade', '电脑端已是最新 v$current，清除升级提示');
        _desktopUpgrade = null;
        notifyListeners();
      }
      return;
    }
    AppLog.i('upgrade', '收到电脑端升级提示: v$current → v$latest (${info['hostName']})');
    _desktopUpgrade = DesktopUpgradeInfo(
      current: current,
      latest: latest,
      urgent: info['urgent'] == true,
      hostName: info['hostName']?.toString() ?? '电脑',
    );
    notifyListeners();
  }

  /// 电脑端升级结果：确认回执（ok=true 已通知升级）或升级失败转发
  void _onDesktopUpgradeResult(Map<String, dynamic> result) {
    final up = _desktopUpgrade;
    if (up == null) return;
    final ok = result['ok'] == true;
    if (ok) {
      AppLog.i('upgrade', '已通知电脑端升级到 v${up.latest}');
      _desktopUpgrade = DesktopUpgradeInfo(
        current: up.current,
        latest: up.latest,
        urgent: up.urgent,
        hostName: up.hostName,
        status: 'confirmed',
      );
    } else {
      AppLog.w('upgrade', '电脑端升级失败: ${result['error']}');
      _desktopUpgrade = DesktopUpgradeInfo(
        current: up.current,
        latest: up.latest,
        urgent: up.urgent,
        hostName: up.hostName,
        status: 'failed',
        error: result['error']?.toString() ?? '升级失败，请到电脑前手动处理',
      );
    }
    notifyListeners();
  }

  /// 管理员确认电脑端升级：服务器校验身份后通知电脑端静默升级
  void confirmDesktopUpgrade() {
    final up = _desktopUpgrade;
    if (up == null || up.status == 'confirmed') return;
    AppLog.i('upgrade', '管理员确认电脑端升级: v${up.current} → v${up.latest}');
    _signaling.confirmDesktopUpgrade();
  }

  /// 关闭电脑端升级提示
  void dismissDesktopUpgrade() {
    if (_desktopUpgrade == null) return;
    _desktopUpgrade = null;
    notifyListeners();
  }

  /// 版本号转数值（v1.5 → 105）：分段解析避免 double 把 5.10 误判为 5.1
  static int _verNum(String v) {
    final parts = v.split('.');
    return (int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0) * 100 +
        (int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0);
  }

  /// 记录断线时未完成的传输（用于重连后自动续传）
  void _captureResumeState() {
    for (final t in transfers) {
      // transferring 或 error 均记录：发送异常/断线会先置 error，
      // 若只记录 transferring 则重连后无法自动续传（用户需手动重传）；
      // done/skipped 为已完成/跳过，不续传
      if (t.status != 'transferring' && t.status != 'error') continue;
      if (t.direction == 'upload' && t.localPath != null) {
        // 去重：反复断连时同一传输可能被多次记录，避免重连后重复续传
        if (_resumeUploads.any((r) => r.requestId == t.id)) continue;
        _resumeUploads.add(ResumeUpload(
          requestId: t.id,
          fileName: t.fileName,
          localPath: t.localPath!,
          offset: t.transferred,
          subPath: _activeUploadShare != null ? sharePath : uploadDirPath,
          shareToken: _activeUploadShare?.token,
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
          shareToken: activeShare?.token,
        );
      }
    }
    AppLog.i('resume', '断点捕获: 上传=${_resumeUploads.length} 下载=${_resumeDownload != null ? 1 : 0}');
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
      AppLog.i('reconnect', '第$_reconnectAttempts次重试，${delay}s后重建连接');
      await Future.delayed(Duration(seconds: delay));
      if (state != ConnectState.lost || _manualDisconnect) return;
      try {
        // 重建信令连接 + 重置 WebRTC（旧 PeerConnection 已失效，等待新 offer）
        await _rtc.init();
        await _signaling.connect(
          serverUrl: server,
          pairCode: code,
          deviceName: 'Android',
          deviceId: deviceId,
          shareToken: _pendingShareToken,
          activationCode: AuthService.instance.activationCode,
          joinByShare: _shareConnectMode,
        );
        // 连接成功后 onConnect 自动 client:join；joined → paired 后电脑端发 offer
        // 若 join 失败（配对码暂不可用，如电脑端重连中）继续循环重试
      } catch (e) {
        AppLog.e('reconnect', '重建连接失败，继续下一轮', e);
      }
    }
  }

  // 重连成功（数据通道恢复）后：自动续传中断的传输
  Future<void> _resumePendingTransfers() async {
    if (_resuming) return;
    _resuming = true;
    _syncWakelock();
    try {
      // ICE connected 先于数据通道 open 触发（实测相差约 0.1 秒），
      // 此时 _rtc.isOpen=false，直接续传会因通道未就绪而失败。
      // 等待通道真正 open（最多 5 秒），超时则保留队列下次重连再试
      for (var i = 0; i < 50; i++) {
        if (_rtc.isOpen) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      while (_resumeUploads.isNotEmpty) {
        final r = _resumeUploads.first;
        AppLog.i('resume',
            '开始续传上传: ${r.fileName} offset=${r.offset} (第${r.attempts + 1}次尝试)');
        final ok = await _resumeUpload(r);
        if (!ok) {
          // 失败不丢队：连接未就绪/握手超时等情况保留记录，
          // 重连成功后会再次尝试；超过上限才丢弃（避免死循环）
          r.attempts++;
          if (r.attempts >= 3) {
            AppLog.e('resume', '续传尝试${r.attempts}次仍失败，丢弃: ${r.fileName}');
            _resumeUploads.removeAt(0);
          }
          // 队头失败不阻塞后续文件：继续处理队列中下一个（避免一个
          // 无法续传的文件（如重名冲突未解决）卡死整批上传）
          continue;
        }
        _resumeUploads.removeAt(0);
        AppLog.i('resume', '续传上传结束: ${r.fileName} => 成功');
      }
      final d = _resumeDownload;
      if (d != null) {
        _resumeDownload = null;
        AppLog.i('resume', '开始续传下载: ${d.fileName} offset=${d.offset}');
        await _resumeDownloadFile(d);
        AppLog.i('resume', '续传下载结束: ${d.fileName}');
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
    if (t == null || t.status == 'done' || t.status == 'skipped') {
      return true; // 记录已结束（成功/跳过），跳过续传
    }
    // 断线时 transferring 的记录同样续传（error 为超时/失败标记，重连后重新尝试）
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
      t.endTime = null; // 重新传输：清除上次结束时间（v5.37+）
      // 续传在重连后进行，连接方式可能已变化：记录实际续传方式
      t.connType = _rtc.connectionType;
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
        if (r.shareToken != null) 'share': r.shareToken,
      });

      final decision =
          await _waitUploadDecision(r.fileName, const Duration(seconds: 5));
      // 必须先处理 conflict：续传请求也可能撞上“正式文件已存在”
      // （上次传输期间文件已完整落盘），电脑端会返回 conflict；
      // 若先判 _acceptOffset==0 会提前放弃（conflict 不回传 offset），
      // 导致续传永远失败（曾实测 app-release.apk 卡在 88% 多次重连均放弃）
      if (decision == 'conflict') {
        // 重连后出现重名冲突：按覆盖处理，覆盖后电脑端以 .part 为准回传 offset
        AppLog.i('resume', '续传时遇到重名冲突，自动按覆盖处理: ${r.fileName}');
        _rtc.sendJson({
          'type': 'file:conflict-resolve',
          'fileName': r.fileName,
          'requestId': r.requestId,
          'action': 'overwrite',
        });
        await _waitUploadDecision(r.fileName, const Duration(seconds: 3));
      } else if (decision == 'busy' || decision == 'rejected') {
        t.finish('error');
        notifyListeners();
        return false;
      }
      // 续传请求必须拿到电脑端 accept 才能定位起点；
      // 若 accept 未到达（超时/异常），盲发会起点错位导致发送超量/文件损坏
      if (startOffset > 0 && _acceptOffset == 0) {
        AppLog.e('resume',
            '续传握手未收到accept（请求offset=$startOffset），放弃本次续传: ${r.fileName}');
        t.finish('error');
        notifyListeners();
        return false;
      }

      // 以电脑端实际续传起点为准（磁盘 .part 大小）；无 offset 表示从头
      final start = _acceptOffset > 0 ? _acceptOffset : 0;
      t.transferred = start;
      notifyListeners();
      AppLog.i('resume',
          '续传起点: offset=$start (请求=${startOffset > 0 ? startOffset : '从头'}) 文件=${size}B ${r.fileName}');

      final raf = await f.open();
      try {
        if (start > 0) await raf.setPosition(start);
        final buf = Uint8List(kChunkSize);
        while (t.status == 'transferring') {
          final n = await raf.readInto(buf);
          if (n <= 0) break;
          // 起点错位保护：进度超过文件总大小说明读取起点错误（正常发送不可能超），
          // 立即终止，避免向电脑端发送超量数据造成 size-mismatch
          if (start + _uploadBytes + n > t.total) {
            AppLog.e('resume',
                '续传进度超限: ${start + _uploadBytes + n} > ${t.total}，起点错位终止 ${r.fileName}');
            t.finish('error');
            notifyListeners();
            return false;
          }
          while (_rtc.bufferedAmount > kBackpressureLimit &&
              t.status == 'transferring') {
            await Future.delayed(const Duration(milliseconds: 5));
          }
          if (t.status != 'transferring') break;
          // 服务器中转(relay)时限速 500KB/s；P2P 直连不限速
          await _rtc.waitSendPermit(n);
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
        AppLog.i('resume', '续传发送完成，发file-complete: ${r.fileName} (${t.transferred}/${t.total})');
        _rtc.sendJson({'type': 'file-complete'});
        while (t.status == 'transferring') {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      AppLog.i('resume', '续传结束: ${r.fileName} 状态=${t.status}');
      return true;
    } catch (e) {
      debugPrint('续传失败 ${r.fileName}: $e');
      if (t.status == 'transferring') {
        t.finish('error');
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
    } catch (e) {
      AppLog.w('resume', '读取续传.part大小失败，使用内存记录 offset=$offset', e);
    }
    AppLog.i('resume', '续传下载请求: ${d.fileName} 请求offset=$offset (内存记录=${d.offset})');
    _rtc.sendJson({
      'type': 'file:download',
      'path': d.path,
      'fileName': d.fileName,
      if (offset > 0) 'offset': offset,
      if (d.shareToken != null) 'share': d.shareToken,
    });
  }

  Future<void> disconnect() async {
    AppLog.i('connect', '用户主动断开连接');
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _connectTimer?.cancel();
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
    _desktopPath = null;
    uploadDirs = [];
    uploadDirLoading = false;
    pendingConflict = null;
    // 多用户与共享状态清理
    isAdmin = false;
    users = [];
    shares.clear();
    allShares.clear();
    _lastShareResult = null;
    _pendingShareToken = null;
    _shareConnectMode = false;
    isShareGuest = false;
    _activeUploadShare = null;
    activeShare = null;
    sharePath = '';
    shareCrumbs.clear();
    shareFiles = [];
    shareLoading = false;
    shareError = null;
    pickFiles = [];
    pickPath = '';
    pickCrumbs.clear();
    pickLoading = false;
    actionMessage = null;
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
      _pendingBrowseList = false;
      AppLog.i('browse', '请求文件列表: path=$dirPath');
      _rtc.sendJson({'type': 'file:list', 'path': dirPath});
    } else {
      // 通道未真正打开时发送会被静默丢弃，挂起等通道打开后补发
      // （实测：open 状态事件早于 channel 赋值，请求在启动瞬间丢失）
      AppLog.w('browse', '请求文件列表时通道未打开，挂起等通道打开');
      _pendingBrowseList = true;
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
    AppLog.i('browse', '进入目录: ${entry.name} (完整路径=${entry.path})');
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
    AppLog.i('browse', '返回目录层级: depth=$depth (原路径=$dirPath)');
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
    AppLog.i('upload', '刷新上传目标目录: path=$uploadDirPath');
    uploadDirLoading = true;
    uploadDirs = [];
    notifyListeners();
    _requestUploadDirs();
  }

  /// 读取上次使用的上传目录（持久化）
  Future<void> _loadRememberedUploadDir() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString(_prefUploadDir);
      if (saved != null && saved.isNotEmpty) {
        _rememberedUploadDir = saved;
        AppLog.i('upload', '上次上传目录: $saved');
      }
    } catch (e) {
      AppLog.w('upload', '读取上次上传目录失败', e);
    }
  }

  /// 保存当前上传目录（持久化，下次启动恢复）
  void _saveUploadDir() {
    if (uploadDirPath.isEmpty) return;
    SharedPreferences.getInstance().then((p) {
      p.setString(_prefUploadDir, uploadDirPath);
    }).catchError((e) {
      AppLog.w('upload', '保存上传目录失败', e);
    });
  }

  /// 校验上次上传目录是否仍存在：请求其文件列表，失败则回退桌面
  void _checkRememberedUploadDir() {
    if (uploadDirPath.isEmpty) return;
    if (!_rtc.isOpen) {
      // 通道未真正打开时 sendJson 走 _channel?.send 会被静默丢弃
      // （实测：open 状态事件早于 channel 赋值 60ms），挂起等打开后补发
      AppLog.w('upload', '通道未打开，推迟上传目录校验');
      _pendingUploadCheck = true;
      return;
    }
    _pendingUploadCheck = false;
    AppLog.i('upload', '校验上次上传目录: $uploadDirPath');
    _rtc.sendJson(
        {'type': 'file:list', 'path': uploadDirPath, 'requestId': 'upload-check'});
  }

  /// 进入上传目标子目录
  void openUploadDir(FileEntry entry) {
    AppLog.i('upload', '进入上传目标目录: ${entry.name} (完整路径=${entry.path})');
    uploadDirPath = entry.path ??
        (uploadDirPath.isEmpty ? entry.name : '$uploadDirPath/${entry.name}');
    _saveUploadDir();
    uploadDirLoading = true;
    uploadDirs = [];
    notifyListeners();
    _requestUploadDirs();
  }

  /// 返回上传目标上级目录
  void navigateUploadDir(int depth) {
    final segs = uploadDirPath.split('/').where((s) => s.isNotEmpty).toList();
    uploadDirPath = segs.take(depth + 1).join('/');
    _saveUploadDir();
    AppLog.i('upload', '返回上传目标上级目录: depth=$depth 新路径=$uploadDirPath');
    uploadDirLoading = true;
    uploadDirs = [];
    notifyListeners();
    _requestUploadDirs();
  }

  // ── 多用户与共享目录 ───────────────────────────────────
  /// 请求用户列表（身份/用户/共享目录）
  void _requestUserInfo() {
    if (_rtc.isOpen) {
      _pendingUserInfo = false;
      _rtc.sendJson({'type': 'user:list'});
    } else {
      // 通道未就绪：挂起，等数据通道真正 OPEN 后补发
      _pendingUserInfo = true;
    }
  }

  /// 刷新用户列表（用户管理页调用）
  void refreshUserList() => _requestUserInfo();

  /// 最近一次共享操作结果（UI 展示二维码）
  ShareEntry? get lastShareResult => _lastShareResult;

  /// 清除共享结果（二维码展示完成后调用）
  void clearLastShareResult() {
    if (_lastShareResult == null) return;
    _lastShareResult = null;
    notifyListeners();
  }

  /// 处理 user:list-result：更新管理员标记、用户列表与我的共享目录
  void _handleUserListResult(ControlMessage msg) {
    final myId = msg.data['myDeviceId']?.toString() ?? deviceId;
    isAdmin = msg.data['isAdmin'] == true;
    users = (msg.data['users'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    // 我的共享目录 = 用户列表中我名下绑定的共享（电脑端以 deviceId 识别）
    shares.clear();
    for (final u in users) {
      if (u['deviceId']?.toString() == myId) {
        shares.addAll((u['shares'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ShareEntry.fromJson(Map<String, dynamic>.from(e))));
        break;
      }
    }
    // 管理员：电脑端全部共享配置（共享文件夹管理页）
    allShares.clear();
    allShares.addAll((msg.data['shares'] as List? ?? [])
        .whereType<Map>()
        .map((e) => ShareEntry.fromJson(Map<String, dynamic>.from(e))));
    AppLog.i('share',
        '用户列表更新: 用户数=${users.length} 我的共享=${shares.length} '
        '全量共享=${allShares.length} 管理员=$isAdmin');
    // 电脑端已有其他管理员：提示是否更换（仅配对用户；取消后本会话不再打扰）
    // v5.16+ 身份二态化：无普通码，激活用户（非共享访客）均有更换资格；
    // 共享访客被电脑端明确拒绝 claim，弹窗只会造成困扰。
    final adminDeviceId = msg.data['adminDeviceId']?.toString() ?? '';
    if (isAdmin) {
      _adminClaimRequest = null;
    } else if (adminDeviceId.isNotEmpty &&
        !_adminClaimDismissed &&
        !isShareGuest) {
      final adminUser = users
          .where((u) => u['deviceId']?.toString() == adminDeviceId)
          .toList();
      String adminName = '管理员';
      if (adminUser.isNotEmpty) {
        final remark = adminUser.first['remark']?.toString() ?? '';
        adminName = remark.isNotEmpty
            ? remark
            : (adminUser.first['name']?.toString() ?? '管理员');
      }
      _adminClaimRequest = AdminClaimRequest(adminName: adminName);
      AppLog.i('share', '电脑端已有管理员($adminName)，等待用户确认更换');
    }
  }

  /// 确认更换：申请成为该电脑端管理员（电脑端校验配对身份后生效）
  void confirmAdminClaim() {
    final req = _adminClaimRequest;
    _adminClaimRequest = null;
    if (req == null) return;
    AppLog.i('share', '确认更换管理员: 现任=${req.adminName}');
    _rtc.sendJson({'type': 'user:claim-admin'});
    notifyListeners();
  }

  /// 拒绝更换：本会话内不再提示
  void rejectAdminClaim() {
    _adminClaimRequest = null;
    _adminClaimDismissed = true;
    notifyListeners();
  }

  // ── 连接密码（v5.4+） ──────────────────────────────────
  /// 读取本电脑保存的连接密码（按配对码区分；未保存返回 null）
  Future<String?> _loadSavedPassword() async {
    final code = _lastCode;
    if (code == null || code.isEmpty) return null;
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString('$_pwdKeyPrefix$code');
    } catch (e) {
      AppLog.w('auth', '读取保存的密码失败', e);
      return null;
    }
  }

  /// 保存本电脑的连接密码
  Future<void> _savePassword(String pwd) async {
    final code = _lastCode;
    if (code == null || code.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('$_pwdKeyPrefix$code', pwd);
      AppLog.i('auth', '连接密码已保存(按配对码区分)');
    } catch (e) {
      AppLog.w('auth', '保存连接密码失败', e);
    }
  }

  /// 清除本电脑保存的连接密码（校验失败时调用，下次需重新输入）
  Future<void> _clearSavedPassword() async {
    final code = _lastCode;
    if (code == null || code.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('$_pwdKeyPrefix$code');
    } catch (e) {
      AppLog.w('auth', '清除连接密码失败', e);
    }
  }

  /// 数据通道建立后自动校验连接密码：本地有密码则验证，无则不校验
  /// （共享访客不参与密码校验：仅访问被共享目录，身份由设备令牌保障）
  void _maybeAuthVerify() {
    if (isShareGuest) return;
    _loadSavedPassword().then((pwd) {
      if (pwd == null || pwd.isEmpty) return;
      AppLog.i('auth', '自动验证连接密码');
      _rtc.sendJson({'type': 'auth:verify', 'password': pwd});
    });
  }

  /// 提交连接密码（密码输入弹窗确认后调用），成功则保存本地并重新连接
  void submitPassword(String pwd) {
    AppLog.i('auth', '提交连接密码');
    _savePassword(pwd);
    _authError = null;
    notifyListeners();
    if (!_rtc.isOpen) {
      // 校验失败被踢出后通道已断：用新密码重新建立连接（open 后自动验证）
      final server = _lastServer;
      final code = _lastCode;
      if (server != null && code != null) {
        _manualDisconnect = false;
        autoMode = false;
        connect(server, code, shareToken: _pendingShareToken);
      }
    } else {
      _rtc.sendJson({'type': 'auth:verify', 'password': pwd});
    }
  }

  /// 主动修改连接密码（需原密码），结果经 auth:pwd-result 回传
  void changePassword(String oldPwd, String newPwd) {
    if (!_rtc.isOpen) return;
    AppLog.i('auth', '请求修改连接密码');
    _rtc.sendJson({
      'type': 'auth:change-pwd',
      'oldPassword': oldPwd,
      'newPassword': newPwd,
    });
  }

  /// 消费密码错误提示（主页弹窗后置空）
  void consumeAuthError() {
    if (_authError == null) return;
    _authError = null;
    notifyListeners();
  }

  // ── 激活码管理（v5.4+，管理员远程发码） ─────────────────
  /// 生成管理员激活码（电脑端本地生成并同步服务器，结果经 user:code-result 回传）
  /// v5.16+ 身份二态化：仅管理员码一种类型
  void generateActCode() {
    if (!_rtc.isOpen || !isAdmin) return;
    AppLog.i('auth', '远程生成管理员激活码');
    _rtc.sendJson({'type': 'user:create-code', 'admin': true});
  }

  /// 撤销激活码
  void revokeActCode(String code) {
    if (!_rtc.isOpen || !isAdmin) return;
    AppLog.i('auth', '远程撤销激活码: $code');
    _rtc.sendJson({'type': 'user:revoke-code', 'code': code});
  }

  /// 远程电源控制（v5.9）：shutdown=关机 / reboot=重启 / cancel=取消挂起操作。
  /// 仅管理员可执行（电脑端同样校验发送者身份，双重防护）
  void remotePower(String action) {
    if (!_rtc.isOpen || !isAdmin) {
      actionMessage = '连接未就绪或您不是管理员，无法远程电源控制';
      notifyListeners();
      return;
    }
    AppLog.i('share', '远程电源控制: $action');
    _rtc.sendJson({'type': 'user:power', 'action': action});
  }

  /// 远程电源控制回执（v5.9）：执行成功后 15 秒内可在手机端取消
  PowerNotice? powerNotice;

  void clearPowerNotice() {
    powerNotice = null;
    notifyListeners();
  }

  // ── 远程自动登录设置（v5.13） ──────────────────────────
  Completer<Map<String, dynamic>>? _autoLoginCompleter;

  /// 发送远程自动登录指令（status/enable/disable），返回回执数据；
  /// 超时或通道未就绪返回 null。密码仅走 P2P 通道，不经服务器
  Future<Map<String, dynamic>?> remoteAutoLogin(
    String action, {
    String? password,
  }) async {
    if (!_rtc.isOpen || !isAdmin) {
      actionMessage = '连接未就绪或您不是管理员，无法设置自动登录';
      notifyListeners();
      return null;
    }
    AppLog.i('share', '远程自动登录设置: $action');
    _autoLoginCompleter = Completer<Map<String, dynamic>>();
    _rtc.sendJson({
      'type': 'user:auto-login',
      'action': action,
      if (password != null && password.isNotEmpty) 'password': password,
    });
    try {
      return await _autoLoginCompleter!.future
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      _autoLoginCompleter = null;
      return null;
    }
  }

  /// 管理员：删除共享（对方将立即失去访问权，权限由电脑端校验）
  void removeShare(String token) {
    AppLog.i('share', '删除共享: $token');
    _rtc.sendJson({'type': 'user:remove-share', 'token': token});
  }

  /// 管理员：修改共享权限（对方即时生效，权限由电脑端校验）
  void updateSharePerms(String token, List<String> perms) {
    AppLog.i('share', '修改共享权限: $token $perms');
    _rtc.sendJson({'type': 'user:update-share', 'token': token, 'perms': perms});
  }

  /// 拉取“共享给我的”列表（v5.4+：凭激活设备令牌，免配对码可见；
  /// v5.19+：共享访客无令牌，凭 deviceId + 服务器绑定记录放行）
  Future<List<ServerShare>> fetchMyShares() async {
    final token = AuthService.instance.deviceToken ?? '';
    if (deviceId.isEmpty) {
      AppLog.w('share', '设备标识为空，无法拉取共享列表');
      return const [];
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse('$defaultServerUrl/api/shares/mine')
          .replace(queryParameters: {
        'deviceId': deviceId,
        'deviceToken': token,
      });
      final req = await client.getUrl(uri);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      AppLog.i('share', '拉取共享列表: HTTP ${res.statusCode} 共${text.length}字符');
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(text);
      if (data is! Map || data['ok'] != true || data['shares'] is! List) {
        AppLog.w('share', '共享列表响应格式异常');
        return const [];
      }
      return (data['shares'] as List)
          .whereType<Map>()
          .map((e) => ServerShare.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      AppLog.e('share', '拉取共享列表失败', e);
      return const [];
    } finally {
      client.close(force: true);
    }
  }

  /// 免配对码连接共享（v4.8+：共享中心页）
  /// 成功后自动打开对应共享目录；失败返回 false（错误信息见 errorMessage）
  Future<bool> connectByShare(ServerShare share) async {
    AppLog.i('share', '免配对码连接共享: ${share.name} (${share.hostName})');
    autoMode = false;
    errorMessage = null;
    await connect(defaultServerUrl, '', shareToken: share.token,
        joinByShare: true);
    // 等待数据通道建立（电脑端上线后握手，最多 20 秒）
    for (var i = 0; i < 200; i++) {
      if (_rtc.isOpen) break;
      if (state == ConnectState.error) break; // 服务器已拒绝（共享失效/电脑离线）
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!_rtc.isOpen) {
      AppLog.w('share', '共享连接失败: 数据通道未建立 (state=$state)');
      return false;
    }
    // 电脑端下发共享列表后，按 token 匹配并打开浏览
    final matches = shares.where((s) => s.token == share.token).toList();
    if (matches.isEmpty) {
      AppLog.w('share', '连接成功但未匹配到共享目录: ${share.token}');
      return false;
    }
    openShare(matches.first);
    return true;
  }

  /// 打开共享目录（进入共享浏览模式）
  void openShare(ShareEntry entry) {
    AppLog.i('share', '打开共享目录: ${entry.name} (${entry.folder})');
    activeShare = entry;
    sharePath = '';
    shareCrumbs.clear();
    shareFiles = [];
    shareLoading = true;
    shareError = null;
    notifyListeners();
    _requestShareList();
  }

  /// 进入共享子目录
  void openShareDir(FileEntry entry) {
    shareCrumbs.add(entry.name);
    sharePath = sharePath.isEmpty ? entry.name : '$sharePath/${entry.name}';
    shareLoading = true;
    shareError = null;
    shareFiles = [];
    notifyListeners();
    _requestShareList();
  }

  /// 返回共享目录上级
  void navigateShareTo(int depth) {
    if (depth < 0) {
      sharePath = '';
      shareCrumbs.clear();
    } else {
      shareCrumbs.removeRange(depth + 1, shareCrumbs.length);
      sharePath = shareCrumbs.join('/');
    }
    shareLoading = true;
    shareError = null;
    shareFiles = [];
    notifyListeners();
    _requestShareList();
  }

  /// 退出共享目录浏览（返回主目录）
  void closeShare() {
    activeShare = null;
    sharePath = '';
    shareCrumbs.clear();
    shareFiles = [];
    shareError = null;
    notifyListeners();
  }

  /// 请求共享目录文件列表
  void _requestShareList() {
    if (!_rtc.isOpen || activeShare == null) return;
    _rtc.sendJson({
      'type': 'file:list',
      'path': sharePath,
      'requestId': 'share-browse',
      'share': activeShare!.token,
    });
  }

  /// 刷新当前共享目录列表（共享浏览页下拉刷新）
  void refreshShareList() {
    if (activeShare == null) return;
    shareLoading = true;
    shareError = null;
    notifyListeners();
    _requestShareList();
  }

  /// 从共享目录下载文件（带权限校验）
  Future<void> downloadShareFile(FileEntry entry) async {
    if (!_rtc.isOpen || entry.isDirectory || activeShare == null) return;
    final rel = sharePath.isEmpty ? entry.name : '$sharePath/${entry.name}';
    AppLog.i('share', '请求下载共享文件: $rel');
    _rtc.sendJson({
      'type': 'file:download',
      'path': rel,
      'fileName': entry.name,
      'share': activeShare!.token,
    });
  }

  /// 删除文件/目录：主目录需管理员；共享目录需 delete 权限
  Future<void> deleteFile(FileEntry entry) async {
    if (!_rtc.isOpen) return;
    final share = activeShare;
    final path = share != null
        ? (sharePath.isEmpty ? entry.name : '$sharePath/${entry.name}')
        : (entry.path ??
            (dirPath.isEmpty ? entry.name : '$dirPath/${entry.name}'));
    AppLog.i('delete', '请求删除: $path (共享=${share != null})');
    _rtc.sendJson({
      'type': 'file:delete',
      'path': path,
      'isDirectory': entry.isDirectory,
      if (share != null) 'share': share.token,
    });
  }

  // ── 管理员操作 ────────────────────────────────────────
  /// 管理员共享文件夹：公开二维码（v5.4+ 去手机号，不再按手机号定向）
  void createShare({
    String? deviceId,
    required String folder,
    required List<String> perms,
  }) {
    if (!_rtc.isOpen) {
      actionMessage = '连接未就绪，无法分享';
      notifyListeners();
      return;
    }
    // 管理员校验交由电脑端裁决：本地标志可能滞后（身份同步延迟），
    // 若确实无权限，电脑端会回 share-result ok=false 并附原因提示
    AppLog.i('share',
        '创建共享: 目标=${deviceId ?? '公开二维码'} 文件夹=$folder 权限=$perms');
    _rtc.sendJson({
      'type': 'user:create-share',
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      'folder': folder,
      'perms': perms,
    });
  }

  /// 踢出用户（仅断开，保留记录）
  void kickUser(String targetDeviceId) {
    if (!_rtc.isOpen || !isAdmin) return;
    AppLog.i('share', '踢出用户: $targetDeviceId');
    _rtc.sendJson({'type': 'user:kick', 'deviceId': targetDeviceId});
  }

  /// 删除用户（断开 + 移除记录与共享）
  void removeUser(String targetDeviceId) {
    if (!_rtc.isOpen || !isAdmin) return;
    AppLog.i('share', '删除用户: $targetDeviceId');
    _rtc.sendJson({'type': 'user:remove', 'deviceId': targetDeviceId});
  }

  /// 已连接时附加共享码（扫描共享二维码且已连同一电脑端）
  void attachShare(String token) {
    if (!_rtc.isOpen) return;
    AppLog.i('share', '附加共享码: $token');
    _rtc.sendJson({'type': 'user:attach-share', 'token': token});
    // v5.10+：已连接电脑扫码附加时服务器无感知，主动上报记录扫码加入绑定，
    // 使该共享持久化出现在“共享给我的”列表（失败不影响附加）
    _reportShareJoin(token);
  }

  /// 上报扫码加入绑定（v5.10+）：POST /api/shares/join 记录 deviceId→token，
  /// 免重复扫码；仅已激活设备可上报（服务器校验设备令牌）
  Future<void> _reportShareJoin(String token) async {
    final t = AuthService.instance.deviceToken;
    if (t == null || t.isEmpty) {
      AppLog.i('share', '未激活，跳过扫码绑定上报');
      return;
    }
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        final req = await client.postUrl(
            Uri.parse('$defaultServerUrl/api/shares/join'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(
            {'deviceId': deviceId, 'deviceToken': t, 'token': token}));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        AppLog.i('share', '上报扫码加入: HTTP ${res.statusCode} $text');
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      AppLog.w('share', '上报扫码加入失败（不影响附加）', e);
    }
  }

  // ── 管理员共享文件夹选择器 ─────────────────────────────
  void requestPickDirs() {
    pickLoading = true;
    pickFiles = [];
    notifyListeners();
    _rtc.sendJson(
        {'type': 'file:list', 'path': pickPath, 'requestId': 'pick'});
  }

  void openPickDir(FileEntry entry) {
    pickCrumbs.add(entry.name);
    pickPath = entry.path ??
        (pickPath.isEmpty ? entry.name : '$pickPath/${entry.name}');
    requestPickDirs();
  }

  void navigatePick(int depth) {
    if (depth < 0) {
      pickCrumbs.clear();
      pickPath = '';
    } else {
      pickCrumbs.removeRange(depth + 1, pickCrumbs.length);
      pickPath = pickCrumbs.join('/');
    }
    requestPickDirs();
  }

  /// 清除操作结果提示
  void clearActionMessage() {
    if (actionMessage == null) return;
    actionMessage = null;
    notifyListeners();
  }

  /// 取出最近一次下载完成信息（UI 展示操作面板后清空）
  DownloadDoneInfo? takeLastDownloadDone() {
    final done = _lastDownloadDone;
    _lastDownloadDone = null;
    return done;
  }

  // ── 下载 ──────────────────────────────────────────────
  Future<void> downloadFile(FileEntry entry) async {
    if (!_rtc.isOpen || entry.isDirectory) return;
    final path = entry.path ??
        (dirPath.isEmpty ? entry.name : '$dirPath/${entry.name}');
    AppLog.i('download', '请求下载: ${entry.name} (path=$path)');
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
    _syncWakelock();
    playFinished = false;
    playUrl = null;
    playError = null;
    notifyListeners();
    final path = entry.path ??
        (dirPath.isEmpty ? entry.name : '$dirPath/${entry.name}');
    AppLog.i('play', '请求在线播放: ${entry.name} (path=$path)');
    _rtc.sendJson({
      'type': 'file:download',
      'path': path,
      'fileName': entry.name,
    });
  }

  /// 结束播放（播放页关闭时调用）：停止本地服务器并清理临时文件
  Future<void> stopPlay() async {
    AppLog.i('play', '结束播放，清理临时文件: ${_playFile?.path}');
    _playMode = false;
    _syncWakelock();
    playFinished = false;
    playUrl = null;
    playError = null;
    final pf = _playFile;
    _playFile = null;
    await _playServer.stop();
    if (pf != null) {
      try {
        if (await pf.exists()) {
          await pf.delete();
          AppLog.i('play', '播放临时文件已删除: ${pf.path}');
        }
      } catch (e) {
        AppLog.w('play', '删除播放临时文件失败', e);
      }
    }
  }

  /// 投屏拉流地址（v5.33+）：局域网可达 + token 防盗播；
  /// 本地 video_player 播放仍用 playUrl（loopback 免 token）。
  /// 播放服务器未就绪或无法获取局域网 IP 时返回 null。
  Future<String?> buildCastUrl() async {
    final p = _playServer.port;
    if (p == null || _playFile == null || _playServer.castToken.isEmpty) {
      return null;
    }
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      InternetAddress? lan;
      for (final i in ifs) {
        for (final a in i.addresses) {
          if (!a.isLoopback && !a.isLinkLocal) {
            lan = a;
            break;
          }
        }
        if (lan != null) break;
      }
      if (lan == null) return null;
      return 'http://${lan.address}:$p/play?token=${_playServer.castToken}';
    } catch (e) {
      AppLog.w('play', '获取局域网地址失败', e);
      return null;
    }
  }

  void _startDownload(ControlMessage msg) {
    final fileName = msg.data['fileName']?.toString() ?? 'unknown';
    final fileSize = (msg.data['fileSize'] as num?)?.toInt() ?? 0;
    AppLog.i('download', '开始接收下载: $fileName size=$fileSize playMode=$_playMode');
    _recvStartMs = DateTime.now().millisecondsSinceEpoch;

    // 准备接收状态：创建保存文件与写入流
    _recvFileName = fileName;
    _syncWakelock();
    _recvExpected = fileSize;
    _recvBytes = 0;
    _recvBuf.clear(); // 新下载开始：清空上次残留的合并缓冲
    _recvBufBytes = 0;
    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (_playMode) {
      // 播放模式：写入临时文件，并启动本地流媒体服务器（边下边播）
      getTemporaryDirectory().then((dir) async {
        if (_recvFileName != fileName) return; // 已被新传输替换
        final f = File(
            '${dir.path}/p2p_play_${DateTime.now().millisecondsSinceEpoch}_$safeName');
        try {
          if (!await _ensureFreeSpace(dir.path, fileSize)) {
            playError = '手机存储空间不足，无法播放';
            _handleRecvError('no-space', '手机存储空间不足，无法播放');
            return;
          }
          _recvFile = f;
          _playFile = f;
          _recvSink = f.openWrite();
          final port = await _playServer.start(
            f,
            isFinished: () => playFinished,
            mime: mimeForVideo(fileName),
            expectedSize: fileSize, // v5.34+ 总大小用于响应头，电视边下边播
          );
          playUrl = 'http://127.0.0.1:$port/play';
          AppLog.i('play', '播放服务器已启动: port=$port mime=${mimeForVideo(fileName)}');
          notifyListeners();
        } catch (e) {
          AppLog.e('play', '启动播放服务器失败', e);
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
        } catch (e) {
          AppLog.w('download', '读取.part文件大小失败: ${part.path}', e);
        }
        AppLog.i('download',
            '续传起点计算: 电脑端offset=$reqOffset 本地.part=$base 文件名=$fileName');
        if (reqOffset < base) {
          base = 0;
          try {
            await part.delete();
          } catch (_) {}
          AppLog.w('download', '电脑端起点早于本地.part，作废本地文件从头重写');
        } else if (reqOffset > base) {
          base = reqOffset;
          AppLog.i('download', '本地.part 缺失/较小，从电脑端起点 $base 开始接收');
        }
        // 空间预检：剩余空间不足时提前拒绝并提示（避免下载中途写盘失败）
        final need = fileSize - base;
        if (need > 0 && !await _ensureFreeSpace(dir.path, need)) {
          _handleRecvError('no-space',
              '手机存储空间不足，无法下载（需 ${(need / 1048576).toStringAsFixed(0)}MB）');
          return;
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
          AppLog.e('download', '创建下载文件失败: ${part.path}', e);
          debugPrint('创建下载文件失败: $e');
          _recvSink = null;
        }
      });
    }

    // 电脑端文件路径（file-meta 携带，断线续传定位用）
    final remotePath = msg.data['path']?.toString();
    _addTransfer(fileName, 'download', fileSize, remotePath: remotePath);
    activeDownloadName = fileName;
    activeDownloadSize = fileSize;
    activeDownloadBytes = 0;
    notifyListeners();
    // 启动接收超时兜底：libwebrtc 对端异常关闭通道时本端可能收不到 CLOSED 回调，
    // 30 秒无数据块即判定通道失效，转入断线重连（保留 .part 供续传）
    _resetRecvTimeout();
    // 启动消费进度上报（自适应流控）：每 500ms 报告已写入磁盘字节数，
    // 电脑端差分出真实消费速率并动态调整发送限速，替代人工猜测的固定限速
    _recvStatsTimer?.cancel();
    _recvStatsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_recvSink == null || _recvFileName == null) return;
      // 已写入磁盘 = 已收到 - 合并缓冲未写部分；buffered 供电脑端拥塞控制
      _rtc.sendJson({'type': 'recv-stats', 'written': _recvBytes - _recvBufBytes, 'buffered': _recvBufBytes});
    });
  }

  Future<void> _finalizeDownload() async {
    _cancelRecvTimeout();
    _recvStatsTimer?.cancel(); // 自适应流控上报停止
    _recvStatsTimer = null;
    final sink = _recvSink;
    _recvSink = null;
    if (sink != null) {
      try {
        // 收尾：先写入合并缓冲中的残留数据（最后不足 1MB 的部分）
        if (_recvBufBytes > 0) {
          sink.add(_recvBuf.takeBytes());
          _recvBufBytes = 0;
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        // 收尾写盘失败（典型：存储空间不足）：不静默，标记失败并提示
        AppLog.e('download', '下载收尾写盘失败: ${_recvFileName ?? ''}', e);
        actionMessage = '存储空间不足，文件写入失败';
        _recvFile = null; // 使下方 success 判定为 false
      }
    }

    final success = _recvFile != null && _recvBytes == _recvExpected;
    final name = _recvFileName ?? '';
    AppLog.i('download', '下载结束: $name $_recvBytes/$_recvExpected B => ${success ? '成功' : '失败'} (playMode=$_playMode)');
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
          AppLog.i('download', '同名文件已存在，重命名为: ${target.path}');
        }
        await _recvFile!.rename(target.path);
        AppLog.i('download', '下载文件已保存: ${target.path}');
        // 通知 UI 弹出"打开/保存到手机/分享"操作面板（不再直接弹系统分享）
        _lastDownloadDone = DownloadDoneInfo(path: target.path, name: safeName);
      } catch (e) {
        AppLog.w('download', '保存下载文件异常', e);
      }
    } else if (!success && _recvFile != null && !playMode) {
      // 下载失败：清理不完整 .part，避免残留干扰后续续传起点判断
      try {
        if (await _recvFile!.exists()) {
          await _recvFile!.delete();
          AppLog.i('download', '已删除不完整的.part文件: ${_recvFile!.path}');
        }
      } catch (e) {
        AppLog.w('download', '删除不完整.part文件失败', e);
      }
    }

    final t = transfers.where((x) => x.fileName == name).toList();
    for (final item in t) {
      item.finish(success ? 'done' : 'error');
      item.transferred = item.total;
    }
    unawaited(_saveTransfers());
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
    _syncWakelock();
  }

  // ── 上传 ──────────────────────────────────────────────
  /// 上传一组文件，返回成功文件数。
  /// 每个文件先与电脑端握手（接受/重名冲突决策），确认后才发送数据；
  /// 等待电脑端对本次所有文件返回确认后才解锁，避免重复提交。
  Future<int> startUpload(List<PlatformFile> picked,
      {ShareEntry? share}) async {
    if (!_rtc.isOpen || picked.isEmpty || uploading) return 0;

    uploading = true;
    _uploadCancelled = false; // 重置停止标志
    _activeUploadShare = share; // 记录上传目标（断线续传定位）
    notifyListeners();
    _syncWakelock();
    final ids = <String>[];

    for (final file in picked) {
      if (_uploadCancelled) break; // 用户手动停止：不再处理后续文件
      TransferItem? t;
      try {
        if (file.path == null) continue; // 无路径文件无法流式读取
        final f = File(file.path!);
        final size = await f.length();
        _uploadBytes = 0;
        _uploadStartMs = DateTime.now().millisecondsSinceEpoch;
        _acceptOffset = 0; // 重置：防止上个文件的 accept 残留影响本次定位
        // v5.25+：同步当前文件到全局进度状态（UploadBanner 显示）
        activeUploadName = file.name;
        activeUploadSize = size;
        activeUploadBytes = 0;
        notifyListeners();

        t = _addTransfer(file.name, 'upload', size, localPath: file.path);
        ids.add(t.id);
        final totalChunks = size == 0 ? 0 : (size / kChunkSize).ceil();
        AppLog.i('upload', '开始上传: ${file.name} size=${size}B chunks=$totalChunks');

        _rtc.sendJson({
          'type': 'file:upload',
          'fileName': file.name,
          'fileSize': size,
          'totalChunks': totalChunks,
          'subPath': share != null ? sharePath : uploadDirPath,
          'requestId': t.id,
          if (share != null) 'share': share.token,
        });

        // 握手：等待电脑端 accept/conflict（兼容旧电脑端：超时直接发送）
        final decision =
            await _waitUploadDecision(file.name, const Duration(seconds: 2));
        AppLog.i('upload', '握手决策: ${file.name} => $decision');
        if (decision == 'conflict') {
          // 文件名冲突：弹出决策对话框等待用户选择
          final action = await _waitConflictResolve(file.name, t.id);
          AppLog.i('upload', '冲突决策: ${file.name} => $action');
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
            t.finish('error');
            notifyListeners();
          }
          continue;
        }

        // 电脑端 accept 可能带 offset（.part 已存在）：从断点续传，避免重复发送
        // （v2.4 电脑端对无 offset 的全新上传会清掉残留 .part，此处为兼容旧电脑端）
        final acceptOff = _acceptOffset;
        final raf = await f.open();
        try {
          if (acceptOff > 0) {
            await raf.setPosition(acceptOff);
            AppLog.i('upload',
                '命中已有.part，从 offset=$acceptOff 续传: ${file.name}');
          }
          final buf = Uint8List(kChunkSize);
          while (true) {
            // 发送期间电脑端拒绝或通道断开：停止本次发送，不再补发数据块
            if (t.status != 'transferring') break;
            final n = await raf.readInto(buf);
            if (n <= 0) break;
            // 起点错位保护：进度超过文件总大小说明定位错误（正常发送不可能超），
            // 立即终止，避免向电脑端发送超量数据造成 size-mismatch（与续传流程一致）
            if (acceptOff + _uploadBytes + n > t.total) {
              AppLog.e('upload',
                  '上传进度超限: ${acceptOff + _uploadBytes + n} > ${t.total}，起点错位终止 ${file.name}');
              t.finish('error');
              notifyListeners();
              break;
            }
            // 背压控制：等待发送缓冲低于阈值（期间被拒绝则放弃）
            while (_rtc.bufferedAmount > kBackpressureLimit &&
                t.status == 'transferring') {
              await Future.delayed(const Duration(milliseconds: 5));
            }
            if (t.status != 'transferring') break;
            // 服务器中转(relay)时限速 500KB/s；P2P 直连不限速
            await _rtc.waitSendPermit(n);
            _rtc.sendBinary(
                n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
            _uploadBytes += n;
            if (_uploadBytes - _lastUploadLogBytes >= 8 * 1024 * 1024) {
              _lastUploadLogBytes = _uploadBytes;
              AppLog.i('upload', '进度: ${file.name} ${t.transferred}/${t.total}B (${t.speed})');
            }
            t.transferred = acceptOff + _uploadBytes;
            t.update(acceptOff + _uploadBytes,
                DateTime.now().millisecondsSinceEpoch - _uploadStartMs);
            activeUploadBytes = t.transferred; // v5.25+：横幅进度同步
            notifyListeners();
          }
        } finally {
          await raf.close();
        }

        if (t.status == 'transferring') {
          AppLog.i('upload', '数据发送完成，等待电脑端确认: ${file.name} (${t.transferred}/${t.total})');
          _rtc.sendJson({'type': 'file-complete'});
          // 串行传输：等电脑端确认后再传下一个文件，避免多文件并发发送
          // 导致电脑端接收状态串扰（上一个文件未结束时新请求被 busy 拒绝）
          while (t.status == 'transferring') {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        }
      } catch (e) {
        // 通道异常/读取失败：标记该文件失败，继续下一个
        AppLog.e('upload', '上传异常: ${file.name}', e);
        debugPrint('上传失败 ${file.name}: $e');
        if (t != null && t.status == 'transferring') {
          t.finish('error');
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
        AppLog.e('upload', '等待电脑端确认超时(15分钟)，强制标记失败');
        for (final id in ids) {
          TransferItem? t;
          for (final x in transfers) {
            if (x.id == id) {
              t = x;
              break;
            }
          }
          if (t != null && t.status == 'transferring') {
            t.finish('error');
            errorMessage = '上传超时，电脑端未确认结果: ${t.fileName}';
          }
        }
        unawaited(_saveTransfers());
        break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    uploading = false;
    _uploadCancelled = false;
    _activeUploadShare = null; // 批次结束清除上传目标记录
    _applyAllAction = null; // 批次结束清除「所有文件」统一处理方式
    activeUploadName = null;
    activeUploadSize = 0;
    activeUploadBytes = 0;
    notifyListeners();
    _syncWakelock();
    return ids
        .where((id) =>
            transfers.any((t) => t.id == id && t.status == 'done'))
        .length;
  }

  /// 用户手动停止上传（v5.25+）：本地中止发送。
  /// 发送循环按 `status != 'transferring'` 跳出，批次确认等待自然结束；
  /// 电脑端无需协议改动——其接收超时兜底会回 ack 失败并清理接收状态。
  void stopUpload() {
    if (!uploading || _uploadCancelled) return;
    _uploadCancelled = true;
    final name = activeUploadName;
    AppLog.i('upload', '用户手动停止上传: $name');
    for (final x in transfers) {
      if (x.direction == 'upload' && x.status == 'transferring') {
        x.finish('error');
      }
    }
    notifyListeners();
    unawaited(_saveTransfers());
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
    if (applyAll != null) {
      // v5.14: 自动应用路径也必须发送 resolve（曾漏发导致电脑端一直等待
      // 决策、手机端超时误发数据、电脑端不回 ack → 永久卡“上传中”）
      _rtc.sendJson({
        'type': 'file:conflict-resolve',
        'fileName': name,
        'requestId': requestId,
        'action': applyAll,
      });
      return applyAll;
    }
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
    if (req == null) {
      AppLog.w('upload', 'resolveConflict 被调用但无待决策冲突，忽略 (action=$action)');
      return;
    }
    AppLog.i('upload', '冲突决策: ${req.fileName} => $action${applyAll ? ' (应用到全部)' : ''}');
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
    AppLog.i('upload', '收到电脑端确认: fileName=${msg.data['fileName']} requestId=${msg.data['requestId']} success=$success reason=$reason');
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
      item.finish('skipped');
    } else {
      item.finish(success ? 'done' : 'error');
    }
    if (success || reason == 'skipped') item.transferred = item.total;
    unawaited(_saveTransfers());
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
    AppLog.i('recv', '收到控制消息: ${msg.type}');
    switch (msg.type) {
      case 'file-list-result':
        final requestId = msg.data['requestId']?.toString() ?? 'browse';
        final parsed = (msg.data['files'] as List? ?? [])
            .whereType<Map>()
            .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        final err = msg.data['error']?.toString();
        AppLog.i('browse',
            '收到文件列表: requestId=$requestId 文件数=${parsed.length} 错误=${err ?? '无'}');
        if (requestId == 'upload-check') {
          // 上次上传目录校验：不存在（电脑端返回错误）时回退桌面
          if (err != null) {
            AppLog.i('upload', '上次上传目录不存在($err)，回退电脑桌面');
            uploadDirPath = _desktopPath ?? '';
            _saveUploadDir();
            _requestUploadDirs();
          } else {
            AppLog.i('upload', '上次上传目录校验通过: $uploadDirPath');
          }
        } else if (requestId == 'upload') {
          uploadDirs = parsed;
          uploadDirLoading = false;
        } else if (requestId == 'share-browse') {
          // 共享目录浏览（路径为共享文件夹内相对路径）
          shareFiles = parsed;
          shareError = err;
          shareLoading = false;
        } else if (requestId == 'pick') {
          // 管理员共享文件夹选择器
          pickFiles = parsed;
          pickLoading = false;
        } else {
          files = parsed;
          listError = err;
          listLoading = false;
        }
        notifyListeners();
        break;
      case 'file:accept':
        // 电脑端确认接收；记录实际续传起点（以电脑端磁盘 .part 大小为准）
        final off = msg.data['offset'];
        if (off is num) {
          _acceptOffset = off.toInt();
          if (_acceptOffset > 0) {
            AppLog.i('upload', '电脑端确认续传起点: offset=$_acceptOffset');
          }
        }
        if (_uploadGate != null) {
          _uploadGate!.complete('accept');
        } else {
          // 冲突决策期间到达：_uploadGate 已清空，标记供下次握手直接通过
          _acceptArrived = true;
          AppLog.i('upload', '握手窗口外的 accept 已到达，标记为下次握手直接通过');
        }
        break;
      case 'file:conflict':
        // 电脑端发现同名文件，等待用户决策
        AppLog.i('upload', '电脑端报告重名冲突，等待用户决策');
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
      case 'file-delete-result':
        // 电脑端删除结果：提示并刷新当前列表
        actionMessage = msg.data['success'] == true
            ? '删除成功'
            : (msg.data['error']?.toString() ?? '删除失败');
        AppLog.i('delete',
            '删除结果: ${msg.data['path']} success=${msg.data['success']}');
        if (activeShare != null) {
          _requestShareList();
        } else {
          _requestFileList();
        }
        notifyListeners();
        break;
      case 'user:list-result':
        _handleUserListResult(msg);
        notifyListeners();
        break;
      case 'user:claim-result':
        if (msg.data['ok'] == true) {
          actionMessage = '您已成为该电脑端的管理员';
          AppLog.i('share', '更换管理员成功');
        } else {
          actionMessage = msg.data['error']?.toString() ?? '更换管理员失败';
          AppLog.w('share', '更换管理员失败: ${msg.data['error']}');
        }
        notifyListeners();
        break;
      case 'user:share-result':
        final ok = msg.data['ok'] == true;
        final error = msg.data['error']?.toString();
        if (ok) {
          final s = msg.data['share'];
          if (s is Map) {
            _lastShareResult =
                ShareEntry.fromJson(Map<String, dynamic>.from(s));
            AppLog.i('share', '共享操作成功: ${_lastShareResult!.name}');
          }
          actionMessage = '共享创建成功';
          _requestUserInfo();
        } else {
          actionMessage = error ?? '共享操作失败';
        }
        notifyListeners();
        break;
      case 'user:share-updated':
        // 电脑端推送：共享配置变更，立即刷新列表
        AppLog.i('share', '收到共享更新通知，自动刷新');
        _requestUserInfo();
        break;
      case 'user:kick-result':
        actionMessage = '已将该用户移出';
        _requestUserInfo();
        notifyListeners();
        break;
      case 'user:remove-result':
        actionMessage = '已删除该用户';
        _requestUserInfo();
        notifyListeners();
        break;
      case 'auth:ok':
        _authError = null;
        AppLog.i('auth', '连接密码校验通过');
        notifyListeners();
        break;
      case 'auth:denied':
        _authError = msg.data['error']?.toString() ?? '连接密码错误';
        _clearSavedPassword();
        // 电脑端稍后会踢出本连接：停止自动重连，等待用户输入正确密码
        _manualDisconnect = true;
        AppLog.w('auth', '连接密码校验失败: $_authError');
        notifyListeners();
        break;
      case 'auth:pwd-result':
        if (msg.data['ok'] == true) {
          actionMessage = '连接密码已修改';
          _clearSavedPassword(); // 旧密码失效，下次连接需用新密码
        } else {
          actionMessage = msg.data['error']?.toString() ?? '修改密码失败';
        }
        notifyListeners();
        break;
      case 'admin:pwd-reset':
        // 管理员重置了连接密码：保存新密码并自动重新校验
        final newPwd = msg.data['password']?.toString() ?? '';
        if (newPwd.isNotEmpty) {
          _savePassword(newPwd);
          if (_rtc.isOpen) {
            _rtc.sendJson({'type': 'auth:verify', 'password': newPwd});
          }
          actionMessage = '连接密码已被管理员重置，已自动更新';
        }
        notifyListeners();
        break;
      case 'user:code-result':
        if (msg.data['ok'] == true) {
          actionMessage = '激活码已生成: ${msg.data['code']}（24小时内有效）';
        } else {
          actionMessage = msg.data['error']?.toString() ?? '激活码生成失败';
        }
        notifyListeners();
        break;
      case 'user:power-result':
        // 远程电源控制回执（v5.9）：成功且非取消 → 显示可取消提示条
        if (msg.data['ok'] == true) {
          final action = msg.data['action']?.toString() ?? '';
          final delay = msg.data['delaySeconds'] is int
              ? msg.data['delaySeconds'] as int
              : 15;
          final canceled = action == 'cancel';
          powerNotice = PowerNotice(
            text: canceled
                ? '已取消关机/重启'
                : '已执行：电脑将在 $delay 秒后${action == 'reboot' ? '重启' : '关机'}',
            delaySeconds: canceled ? 3 : delay,
          );
          AppLog.i('share', '远程电源控制成功: ${canceled ? '已取消' : action}');
        } else {
          actionMessage =
              msg.data['error']?.toString() ?? '远程电源控制失败';
          AppLog.w('share', '远程电源控制失败: ${msg.data['error']}');
        }
        notifyListeners();
        break;
      case 'user:auto-login-result':
        // 远程自动登录设置回执（v5.13）：由发起方 await 接收
        final c = _autoLoginCompleter;
        _autoLoginCompleter = null;
        c?.complete(msg.data);
        break;
    }
  }

  /// 存储空间预检：剩余空间不足返回 false；查询失败时放行（由写盘失败兕底）
  Future<bool> _ensureFreeSpace(String dirPath, int needBytes) async {
    try {
      const ch = MethodChannel('p2p/storage');
      final free =
          await ch.invokeMethod<double>('getFreeSpace', {'dir': dirPath}) ?? -1;
      AppLog.i('download',
          '空间预检: 可用=${free < 0 ? '未知' : '${(free / 1048576).toStringAsFixed(0)}MB'} 需要=${(needBytes / 1048576).toStringAsFixed(0)}MB');
      if (free < 0) return true;
      return free >= needBytes;
    } catch (e) {
      AppLog.w('download', '空间预检失败，放行（写盘失败兕底）', e);
      return true;
    }
  }

  /// 接收失败统一处理：提示 + 通知电脑端中止发送 + 清理接收状态。
  /// 背景：手机端写盘失败（存储不足）若不通知电脑端，电脑端会发完并报
  /// "完成"而手机端卡在"正在下载"（曾实测出现该现象）
  void _handleRecvError(String reason, String message) {
    final name = _recvFileName ?? '';
    AppLog.e('download', '接收中止: $message (fileName=$name)');
    actionMessage = message;
    _cancelRecvTimeout();
    _recvStatsTimer?.cancel();
    _recvStatsTimer = null;
    final sink = _recvSink;
    _recvSink = null;
    if (sink != null) {
      try {
        if (_recvBufBytes > 0) sink.add(_recvBuf.takeBytes());
        sink.close();
      } catch (_) {}
    }
    _recvBufBytes = 0;
    if (name.isNotEmpty) {
      _rtc.sendJson({'type': 'recv-error', 'fileName': name, 'reason': reason});
    }
    _recvFile = null;
    _recvFileName = null;
    _recvExpected = 0;
    _recvBytes = 0;
    activeDownloadName = null;
    notifyListeners();
  }

  /// 用户手动停止下载：通知电脑端中止发送 + 删除不完整的 .part 文件
  void stopDownload() {
    final name = _recvFileName;
    if (name == null || _recvSink == null) return;
    AppLog.i('download', '用户手动停止下载: $name');
    final f = _recvFile;
    _handleRecvError('user-cancel', '已停止下载「$name」');
    // 停止的下载记录标记失败：避免重启后仍显示"传输中"
    for (final x in transfers) {
      if (x.direction == 'download' &&
          x.fileName == name &&
          x.status == 'transferring') {
        x.finish('error');
      }
    }
    unawaited(_saveTransfers());
    // 手动停止：删除 .part 残留（避免占用空间），不再续传
    if (f != null) {
      unawaited(f.exists().then((ok) {
        if (ok) return f.delete();
        return Future.value();
      }).catchError((e) {
        AppLog.w('download', '删除不完整.part文件失败', e);
      }));
    }
  }

  void _onBinary(Uint8List chunk) {
    // 收到数据块：重置接收超时定时器（数据到达即通道活性证明）
    _resetRecvTimeout();
    final sink = _recvSink;
    if (sink == null) return;
    // 写盘合并：积攒到 1MB 一次性写入，减少小写盘调用次数
    // （逐块 add 时 IOSink 以 8KB 为单位提交写盘，64KB 块会被拆成 8 次）
    _recvBuf.add(chunk);
    _recvBufBytes += chunk.length;
    if (_recvBufBytes >= _recvFlushSize) {
      try {
        sink.add(_recvBuf.takeBytes());
        _recvBufBytes = 0;
      } catch (e) {
        // 写盘失败（典型：存储空间不足）：中止并通知电脑端，
        // 避免电脑端继续发送、手机端卡在"正在下载"
        _recvBufBytes = 0;
        _handleRecvError('no-space', '手机存储空间不足，下载已中止');
        return;
      }
    }
    _recvBytes += chunk.length;
    // 进度日志：每 1MB 记录一次（诊断断链：断之前必有记录，观察实际接收量）
    if (_recvBytes - _lastDownloadLogBytes >= 1024 * 1024) {
      _lastDownloadLogBytes = _recvBytes;
      AppLog.i('download', '进度: $_recvFileName $_recvBytes/${_recvExpected}B');
    }
    // 进度 UI 节流刷新：高速直连下若每块(64KB)都 notifyListeners，
    // 主线程会被 UI 重建占满，接收消息处理变慢、SCTP 接收窗口耗尽，
    // 底层终止数据通道（曾导致直连下载 100ms 必断）；改为 250ms 节流
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastDownloadNotifyMs < 250) return;
    _lastDownloadNotifyMs = now;
    final t = transfers.where((x) => x.fileName == _recvFileName).toList();
    for (final item in t) {
      item.update(_recvBytes, now - _recvStartMs);
    }
    activeDownloadBytes = _recvBytes;
    notifyListeners();
  }

  // ── 下载接收超时兜底 ──────────────────────────────────
  /// 重置接收超时定时器：每次收到数据块时调用（通道活性证明）
  void _resetRecvTimeout() {
    // 仅在活跃下载期间生效：下载结束/清理后到达的残余数据不启动定时器
    if (_recvFileName == null) return;
    _recvTimeoutTimer?.cancel();
    _recvTimeoutTimer = Timer(const Duration(seconds: 30), _onRecvTimeout);
  }

  void _cancelRecvTimeout() {
    _recvTimeoutTimer?.cancel();
    _recvTimeoutTimer = null;
  }

  /// 30 秒无数据块：判定数据通道已失效（对端异常关闭时本端收不到 CLOSED 回调），
  /// 转入断线处理自动重连；_captureResumeState 记录断点、磁盘保留 .part 供续传
  void _onRecvTimeout() {
    _recvTimeoutTimer = null;
    AppLog.w('download',
        '接收超时(30s无数据): $_recvFileName $_recvBytes/$_recvExpected B，判定通道失效，自动重连（保留.part供续传）');
    _onPeerLost();
  }

  // ── 内部工具 ──────────────────────────────────────────
  /// 传输记录保留天数（超过自动清理）
  static const int _transferRetentionDays = 7;

  /// 传输记录持久化文件（App 重启后仍可查看最近 7 天记录）
  Future<File> _transfersFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/transfers.json');
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

  /// 启动时加载历史传输记录（按保留期清理过期记录）
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
        // App 进程被杀时正在传输的记录恢复为失败（实际传输已中断）
        if (t.status == 'transferring') t.finish('error');
      }
      transfers.addAll(items);
      AppLog.i('transfer', '加载历史传输记录: ${items.length} 条');
    } catch (e) {
      AppLog.w('transfer', '加载传输记录失败', e);
    }
  }

  TransferItem _addTransfer(String name, String direction, int total,
      {String? localPath, String? remotePath}) {
    // 传输记录仅保留 7 天：新增记录时清理过期记录（运行期间累积的旧记录自动消失，
    // 避免列表无限增长）
    final cutoff = DateTime.now()
        .subtract(const Duration(days: _transferRetentionDays));
    transfers.removeWhere((x) => x.startTime.isBefore(cutoff));
    final t = TransferItem(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: name,
      direction: direction,
      total: total,
      startTime: DateTime.now(),
      // 快照传输创建时的连接方式（传输记录显示的是本次传输实际方式，
      // 而非当前连接状态；续传时在 _resumeUpload 中更新为续传时的方式）
      connType: _rtc.connectionType,
      // v5.37+ 快照传输对象电脑端名称（完成后显示；无连接时兜底'电脑'）
      peerName: hostName ?? '电脑',
      // 本地/电脑端文件路径：断点捕获依赖它定位续传文件
      // （曾缺失导致 _captureResumeState 永远捕获不到上传/下载）
      localPath: localPath,
      remotePath: remotePath,
    );
    transfers.insert(0, t);
    unawaited(_saveTransfers());
    return t;
  }

  /// 删除单条传输记录（v5.37+ 手动删除，含持久化）
  void removeTransfer(String id) {
    transfers.removeWhere((x) => x.id == id);
    notifyListeners();
    unawaited(_saveTransfers());
  }

  void _cleanupReceive() {
    _cancelRecvTimeout();
    _recvStatsTimer?.cancel(); // 自适应流控上报停止
    _recvStatsTimer = null;
    final sink = _recvSink;
    _recvSink = null;
    if (sink != null) {
      try {
        // 断链收尾：残留缓冲也写入 .part，保证磁盘数据与 _recvBytes 一致（续传不丢尾部）
        if (_recvBufBytes > 0) {
          sink.add(_recvBuf.takeBytes());
          _recvBufBytes = 0;
        }
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
    _syncWakelock();
  }

  // ── 保持唤醒（防止锁屏/休眠导致传输中断） ────────────────
  bool _wakelockOn = false;

  Future<void> _syncWakelock() async {
    final need = uploading || _recvFileName != null || _playMode;
    if (need == _wakelockOn) return;
    _wakelockOn = need;
    try {
      if (need) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
      AppLog.i('awake', need ? '传输进行中，保持设备唤醒' : '传输结束，释放唤醒锁');
    } catch (e) {
      AppLog.w('awake', '唤醒锁操作失败', e);
    }
  }

  /// 保存路径（应用文档目录下 P2P 下载）
  static Future<Directory> downloadDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/P2P下载');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 配对历史存储文件（应用私有目录，保存最近连接过的电脑/共享文件夹）
  static Future<File> _pairInfoFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/pair_info.json');
  }

  /// 读取全部配对历史（按最近连接时间倒序）。
  /// 兼容旧版单对象格式：自动迁移为列表（并统一默认服务器地址）。
  Future<List<PairInfo>> loadPairInfos() async {
    try {
      final f = await _pairInfoFile();
      if (!await f.exists()) {
        AppLog.i('connect', '无配对历史');
        return [];
      }
      final data = jsonDecode(await f.readAsString());
      final list = <PairInfo>[];
      if (data is List) {
        for (final e in data.whereType<Map>()) {
          final p = PairInfo.fromJson(Map<String, dynamic>.from(e));
          if (p.server.isNotEmpty && p.code.isNotEmpty) list.add(p);
        }
      } else if (data is Map<String, dynamic>) {
        // 旧版单对象：迁移为列表（历史测试版本可能保存了非默认地址
        // 如兼容端口 48828，统一迁移为默认地址避免升级后连不上）
        var p = PairInfo.fromJson(data);
        if (p.server.isNotEmpty && p.code.isNotEmpty) {
          if (p.server != defaultServerUrl) {
            AppLog.w('connect',
                '配对信息地址非默认(${p.server})，迁移为 $defaultServerUrl');
            p = PairInfo(
                server: defaultServerUrl,
                code: p.code,
                name: p.name,
                lastAt: p.lastAt,
                shareToken: p.shareToken);
          }
          list.add(p);
          await _writePairInfos(list);
        }
      }
      // v5.20+：清洗历史共享记录（v5.19 及更早版本的共享连接也会写入
      // pair_info.json，导致非管理员电脑出现在「切换连接目标」）；
      // 共享入口已由「共享给我的」（服务器绑定）承担，记录冗余
      final before = list.length;
      list.removeWhere((p) => p.isShare);
      if (list.length != before) {
        AppLog.i('connect', '清洗历史共享记录: 移除 ${before - list.length} 条');
        await _writePairInfos(list);
      }
      list.sort((a, b) => (b.lastAt ??
              DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.lastAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
      AppLog.i('connect', '读取配对历史: ${list.length} 条');
      return list;
    } catch (e) {
      AppLog.e('connect', '读取配对历史失败', e);
      return [];
    }
  }

  Future<void> _writePairInfos(List<PairInfo> list) async {
    try {
      final f = await _pairInfoFile();
      await f.writeAsString(
          jsonEncode(list.map((p) => p.toJson()).toList()));
    } catch (e) {
      AppLog.e('connect', '写入配对历史失败', e);
    }
  }

  /// 保存/更新一条配对历史：同一 server+code+shareToken 合并更新连接时间；
  /// 上限 10 条，超出丢弃最旧记录
  Future<void> savePairInfo(String server, String code,
      {String? name, String? shareToken}) async {
    try {
      final list = await loadPairInfos();
      list.removeWhere((p) =>
          p.server == server &&
          p.code == code &&
          (p.shareToken ?? '') == (shareToken ?? ''));
      list.insert(
          0,
          PairInfo(
              server: server,
              code: code,
              name: name,
              lastAt: DateTime.now(),
              shareToken: shareToken));
      if (list.length > 10) list.removeRange(10, list.length);
      await _writePairInfos(list);
      AppLog.i('connect',
          '配对历史已保存: server=$server${shareToken != null ? ' (共享)' : ''}');
    } catch (e) {
      AppLog.e('connect', '保存配对历史失败（不影响主流程）', e);
    }
  }

  /// 删除一条配对历史
  Future<void> removePairInfo(String server, String code,
      {String? shareToken}) async {
    try {
      final list = await loadPairInfos();
      final before = list.length;
      list.removeWhere((p) =>
          p.server == server &&
          p.code == code &&
          (p.shareToken ?? '') == (shareToken ?? ''));
      if (list.length != before) await _writePairInfos(list);
    } catch (e) {
      AppLog.e('connect', '删除配对历史失败', e);
    }
  }

  /// 读取最近一次配对的电脑（不含共享记录，用于启动自动直连）
  Future<PairInfo?> loadPairInfo() async {
    final list = await loadPairInfos();
    for (final p in list) {
      if (!p.isShare) return p;
    }
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
