import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'app_log.dart';
import 'machine_id.dart';
import 'version.dart';

/// 发送限速器（令牌桶）：中转(relay)限 500KB/s，直连(direct)限 16MB/s 兜底；
/// 支持 setRate 动态调整（自适应流控：按手机端实测消费速率实时调速）
class SendRateLimiter {
  // 桶容量上限：空闲期令牌最多攒 512KB，防止下载开始时按旧速率攒出的
  // 大量突发（曾实测 16MB 满桶 → 39-104MB/s 瞬时速度打爆接收窗口断链）
  static const double _maxBurst = 512 * 1024;

  double rate; // 字节/秒（可变：自适应流控动态调整）
  double _tokens;
  int _lastMs;

  // 初始空桶：限速立即生效。曾初始化为满桶(rate)，导致下载前约 1 秒
  // 完全不限速（实测直连 21MB/s），断链恰好发生在该窗口内，限速形同虚设
  SendRateLimiter(this.rate)
      : _tokens = 0,
        _lastMs = DateTime.now().millisecondsSinceEpoch;

  /// 动态调整速率（自适应流控）：新速率低于当前令牌时收窄桶，
  /// 避免按旧速率攒出的突发量直接放行
  void setRate(double newRate) {
    rate = newRate;
    final cap = rate < _maxBurst ? rate : _maxBurst;
    if (_tokens > cap) _tokens = cap;
  }

  /// 申请发送 [bytes] 字节，速率不足时按需等待（桶容量上限 512KB，稳态精确限速）
  Future<void> acquire(int bytes) async {
    while (true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - _lastMs;
      _lastMs = now;
      final cap = rate < _maxBurst ? rate : _maxBurst;
      _tokens = (_tokens + rate * elapsed / 1000).clamp(0.0, cap);
      if (_tokens >= bytes) {
        _tokens -= bytes;
        return;
      }
      final need = bytes - _tokens;
      await Future.delayed(
          Duration(milliseconds: (need / rate * 1000).ceil()));
    }
  }
}

/// 单个手机端的对等会话（多用户：一个电脑端可同时连接多台手机）
class PeerSession {
  final String clientId; // 服务器 socket id（信令路由标识）
  String deviceId; // 手机端设备唯一标识（用户标识，可能为空）
  String clientName;
  String? shareToken; // 首次加入时携带的共享码（共享访客）
  RTCPeerConnection? pc;
  RTCDataChannel? channel;
  SendRateLimiter? rateLimiter;
  String connectionType = 'unknown'; // direct / relay / unknown
  // ── 自适应流控（recv-stats 反馈） ──────────────────────────
  // 手机端周期性上报「已写入磁盘字节」，差分计算真实消费速率，
  // 动态调整发送限速，替代人工猜测的固定限速
  int _lastConsumeBytes = 0;
  int _lastConsumeMs = 0;
  double _consumeRate = 0; // EMA 平滑后的消费速率估计（字节/秒）
  bool _adaptEnabled = false; // 仅 direct 模式启用（relay 固定 500KB/s）
  Timer? disconnectGraceTimer;
  /// 周期探测定时器：连接期间每 15s 复查一次连接方式，
  /// 避免首次探测失败/网络切换后一直停留在“探测中…”
  Timer? connProbeTimer;
  /// 手机端请求中止发送（典型：接收写盘失败/存储空间不足）：
  /// 发送循环检查该标志后立即中止，避免电脑端发完报"完成"
  bool abortRequested = false;

  PeerSession({
    required this.clientId,
    required this.deviceId,
    required this.clientName,
    this.shareToken,
  }) {
    // 连接建立时立即启用限速（探测完成前用保守的 500KB/s）：rateLimiter
    // 若为空，自动续传在 Open 后 94ms 即启动、先于探测完成，会以不限速
    // 满速发送（实测 128MB/s）打爆手机端接收窗口断链；探测完成后
    // setRelayMode 会按实际连接方式切换限速
    rateLimiter = SendRateLimiter(HostService.relayMaxRate);
  }

  bool get isOpen => channel?.state == RTCDataChannelState.RTCDataChannelOpen;
  int get bufferedAmount => channel?.bufferedAmount ?? 0;

  /// 根据连接方式启停发送限速：
  /// 中转 500KB/s（服务器带宽有限）；直连 16MB/s 初始值，收到手机端
  /// recv-stats 消费+缓冲反馈后自适应调整（无积压试探加速/有积压回落）
  void setRelayMode(bool relay) {
    _adaptEnabled = !relay;
    rateLimiter = SendRateLimiter(
        relay ? HostService.relayMaxRate : HostService.directMaxRate);
    AppLog.i('conn', '[$clientName] '
        '${relay ? '服务器中转：发送限速 500KB/s 已启用' : 'P2P 直连：发送限速 16MB/s 已启用（自适应流控待反馈）'}');
  }

  /// 收到手机端消费进度反馈：差分计算消费速率并动态调整发送限速。
  /// 策略（v4.4 重构，汲取两轮教训）：
  /// - 无写盘积压（buffered < 512KB）→ 限速 = 消费速率 ×1.05 小步试探
  ///   （永不衰减；超调仅 5%，SCTP 流控可平滑吸收，不会打爆接收窗口）
  /// - 写盘滞后（512KB~2MB）→ 限速 = 消费速率（跟随，不乘系数）
  /// - 积压增长（>2MB）→ 限速 = 消费速率 ×0.8（回落防打爆）
  /// 历史教训：
  /// ① v4.3 固定 ×1.5 加速：手机端 Dart 层缓冲看不到 native SCTP 接收缓冲
  ///    积压（无线带宽瓶颈时发送速率一路爬升远超带宽 → 缓冲打爆断链）；
  /// ② v4.2 固定 ×0.85：稳态消费≈限速 → 每周期衰减 15%，大文件越传越慢。
  void onConsumeStats(int writtenBytes, int bufferedBytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastConsumeMs > 0 && now > _lastConsumeMs) {
      final dt = (now - _lastConsumeMs) / 1000.0;
      final dbytes = writtenBytes - _lastConsumeBytes;
      if (dt > 0 && dbytes > 0) {
        final sample = dbytes / dt;
        // EMA 平滑：新样本权重 30%，抑制抖动
        _consumeRate =
            _consumeRate == 0 ? sample : _consumeRate * 0.7 + sample * 0.3;
        if (_adaptEnabled) {
          final rl = rateLimiter;
          if (rl != null) {
            const idleBuf = 512 * 1024;      // 无积压阈值
            const busyBuf = 2 * 1024 * 1024; // 积压回落阈值
            double target;
            if (bufferedBytes > busyBuf) {
              target = _consumeRate * 0.8; // 积压增长 → 回落
            } else if (bufferedBytes > idleBuf) {
              target = _consumeRate; // 写盘滞后 → 跟随
            } else {
              target = _consumeRate * 1.05; // 无积压 → 小步试探加速
            }
            if (target < HostService.relayMaxRate) {
              target = HostService.relayMaxRate;
            }
            if (target > HostService.directRateCeiling) {
              target = HostService.directRateCeiling;
            }
            rl.setRate(target);
            AppLog.i('conn',
                '[$clientName] 自适应限速: 消费=${(_consumeRate / 1024).toStringAsFixed(0)}KB/s 缓冲=${(bufferedBytes / 1024).toStringAsFixed(0)}KB → 发送限速=${(target / 1024).toStringAsFixed(0)}KB/s');
          }
        }
      }
    }
    _lastConsumeBytes = writtenBytes;
    _lastConsumeMs = now;
  }

  /// 发送前调用：等待限速许可（直连/未探测时立即放行）
  Future<void> waitSendPermit(int bytes) async {
    await rateLimiter?.acquire(bytes);
  }

  void cancelGraceTimer() {
    disconnectGraceTimer?.cancel();
    disconnectGraceTimer = null;
  }

  void cancelConnProbe() {
    connProbeTimer?.cancel();
    connProbeTimer = null;
  }
}

/// 电脑端 Host 服务：信令注册 + 多手机端 WebRTC 发起方（offerer）+ 数据通道
///
/// 与 p2p-app/server.js 和手机端 (flutter_webrtc answerer) 完全兼容：
/// - 注册: host:register → host:registered {pairCode}
/// - 手机加入: host:client-joined {clientInfo{id,deviceId,shareToken}} → 发起 offer
/// - 信令: signal:host→client {to} / signal:server→host {from}
/// - 数据通道由本端主动创建（手机端通过 onDataChannel 接收）
class HostService {
  io.Socket? _socket;
  final Map<String, PeerSession> _sessions = {}; // clientId -> session
  String _serverUrl = '';

  /// 主机令牌（v5.0+）：本地生成持久化，注册时上报服务器，
  /// 共享同步 HTTP 接口凭此认证（防伪造共享上报）
  String hostToken = _loadOrCreateHostToken();

  /// 读取/生成主机令牌（%APPDATA%/p2p_desktop/host_token，无则生成 32 位随机）
  static String _loadOrCreateHostToken() {
    try {
      final base = Platform.environment['APPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.systemTemp.path;
      final dir = Directory('$base/p2p_desktop');
      final f = File('${dir.path}/host_token');
      if (f.existsSync()) {
        final saved = f.readAsStringSync().trim();
        if (saved.length >= 16) return saved;
      }
      final rand = Random.secure();
      final token =
          List.generate(32, (_) => rand.nextInt(16).toRadixString(16)).join();
      dir.createSync(recursive: true);
      f.writeAsStringSync(token);
      return token;
    } catch (e) {
      AppLog.w('host', '生成主机令牌失败', e);
      return '';
    }
  }
  // ── 自动重连（socket 断线后保持注册状态，等待手机重新加入） ──
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  /// 网络类型变化监听（A方案）：WiFi↔以太网切换时重启 ICE 重新选路，
  /// 期望中转会话切回直连（重选失败则维持中转，不影响连接）
  StreamSubscription<List<ConnectivityResult>>? _netSub;

  // ── 对外回调 ────────────────────────────────────────────
  void Function(String pairCode)? onRegistered;
  void Function(Map<String, dynamic> clientInfo)? onClientJoined;
  void Function(String clientId, String deviceId)? onPeerDisconnected;
  void Function(String reason)? onError;
  void Function(String clientId, dynamic data)? onData; // 原始消息（String 或 Uint8List）
  void Function(String clientId, bool open)? onChannelState;
  void Function(String pairCode)? onPairCodeChanged; // 配对码被重新生成
  void Function(String clientId, String type)? onConnectionType;
  /// 被服务器/管理员踢出
  void Function(String reason)? onKicked;
  /// 激活码被手机端兑换（服务器通知，电脑端管理页标记已用）
  void Function(String code)? onCodeUsed;

  /// 当前在线手机端会话列表（clientId -> session）
  Map<String, PeerSession> get sessions => _sessions;

  /// 设备名称（用户可备注，注册时上报，手机端选择连接时展示）
  String deviceName = '电脑-桌面';

  /// 当前未用激活码列表（v5.9+：注册时全量携带，增删后 syncActCodes 增量同步）
  List<Map<String, String>> activationCodes = [];

  /// 服务器中转时的最大发送速率：500KB/s
  static const double relayMaxRate = 500 * 1024;
  /// P2P 直连时的初始发送速率：16MB/s（已验证零积压稳定版；自适应流控接管后
  /// 会按手机端消费能力爬升/回落，上限见 directRateCeiling）
  static const double directMaxRate = 16 * 1024 * 1024;
  /// 自适应流控的发送速率上限：128MB/s（256KB 分块后手机端消费上限已远超 16MB）
  static const double directRateCeiling = 128 * 1024 * 1024;

  bool get isConnected => _socket?.connected ?? false;

  /// TURN 中继凭证（由 host:client-joined 携带，创建 PeerConnection 前设置）
  Map<String, dynamic>? turnConfig;

  /// 连接信令服务器并注册为主机
  Future<void> connect(String serverUrl) async {
    await dispose();
    _disposed = false;
    _reconnectAttempts = 0;
    _serverUrl = serverUrl.replaceAll(RegExp(r'/$'), '');
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      _reconnectAttempts = 0;
      AppLog.i('host', '信令服务器已连接，发送 host:register (name=$deviceName)');
      _socket!.emit('host:register', {
        'deviceName': deviceName,
        // 版本号：服务器配对日志记录电脑端版本，便于排查版本差异问题
        'version': appVersion,
        // 桌面绝对路径：手机端默认上传目录（我的电脑模式下有效）
        'desktop': _desktopPath(),
        // 本机硬件 ID：服务器据此分配设备专属配对码（每台电脑一个码，
        // 同一台电脑重连/重启后码不变）
        'deviceId': MachineId.get(),
        // 主机令牌：共享同步 HTTP 接口认证（v5.0+）
        'hostToken': hostToken,
        // 激活码列表（v5.9+）：服务器据此响应手机端 /api/activate
        'activationCodes': activationCodes,
      });
    });

    _socket!.on('host:registered', (data) {
      if (data is Map) {
        AppLog.i('host', '收到 host:registered: ${data['pairCode']}');
        onRegistered?.call(data['pairCode']?.toString() ?? '');
      }
    });

    // 配对码被重新生成（服务器广播）
    _socket!.on('pair:code-changed', (data) {
      if (data is Map) {
        onPairCodeChanged?.call(data['pairCode']?.toString() ?? '');
      }
    });

    _socket!.on('host:client-joined', (data) {
      AppLog.i('host', '收到 host:client-joined');
      onClientJoined?.call(
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{});
    });

    // 激活码被手机端兑换（v5.9+）：管理页标记已用
    _socket!.on('host:code-used', (data) {
      final code =
          data is Map ? data['code']?.toString() ?? '' : '';
      if (code.isNotEmpty) {
        AppLog.i('host', '激活码已被手机端使用: $code');
        onCodeUsed?.call(code);
      }
    });

    _socket!.on('signal:server→host', (data) {
      if (data is Map && data['signal'] is Map) {
        final signal = Map<String, dynamic>.from(data['signal'] as Map);
        final from = data['from']?.toString() ?? '';
        AppLog.i('host', '收到信令: ${signal['type']} from=$from');
        _handleSignal(from, signal);
      }
    });

    _socket!.on('peer:disconnected', (data) {
      String clientId = '';
      String deviceId = '';
      if (data is Map) {
        clientId = data['clientId']?.toString() ?? '';
        deviceId = data['deviceId']?.toString() ?? '';
      }
      AppLog.i('host', '收到 peer:disconnected clientId=$clientId');
      onPeerDisconnected?.call(clientId, deviceId);
    });

    _socket!.on('peer:kicked', (data) {
      final reason =
          data is Map ? data['reason']?.toString() ?? '已被移出' : '已被移出';
      AppLog.i('host', '收到 peer:kicked: $reason');
      onKicked?.call(reason);
    });

    _socket!.on('connect_error', (e) {
      AppLog.e('host', '无法连接信令服务器', e);
      onError?.call('无法连接信令服务器: $e');
    });

    // socket 断线：自动重连（指数退避 1s→30s），重连后自动重新注册
    _socket!.onDisconnect((_) {
      AppLog.i('host', '信令连接断开，调度自动重连');
      _scheduleReconnect();
    });

    _socket!.connect();
    _startNetworkWatch();
  }

  /// 网络类型变化监听：对当前中转(relay)的会话重启 ICE 重新选路，
  /// 期望恢复直连（ICE 先试直连后中转）；重选失败维持原路径不中断
  void _startNetworkWatch() {
    _netSub ??= Connectivity().onConnectivityChanged.listen((results) {
      AppLog.i('conn', '网络类型变化: ${results.join(",")}');
      for (final s in _sessions.values) {
        if (s.isOpen && s.connectionType == 'relay') {
          _restartIce(s);
        }
      }
    });
  }

  void _stopNetworkWatch() {
    _netSub?.cancel();
    _netSub = null;
  }

  /// 重启指定会话的 ICE 重新选路：原生 restartIce 使下次 createOffer 携带
  /// 新 ice-ufrag（ICE restart 标记），重协商后 ICE 按“先直连后中转”
  /// 重新尝试；数据通道保持打开，传输短暂停顿后自动恢复
  /// （失败时维持原路径，不影响连接）
  Future<void> _restartIce(PeerSession session) async {
    final pc = session.pc;
    if (pc == null || !session.isOpen) return;
    try {
      AppLog.i('conn', '重启 ICE 重新选路 [${session.clientName}]（期望恢复直连）');
      await pc.restartIce();
      // 等待 ICE restart 状态就绪，确保新 offer 包含更新后的 ice-ufrag
      await Future.delayed(const Duration(milliseconds: 200));
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _sendSignal(session.clientId, {'type': 'offer', 'sdp': offer.sdp});
    } catch (e) {
      AppLog.w('conn', '重启 ICE 失败 [${session.clientName}]（维持当前路径）', e);
    }
  }

  /// 调度 socket 自动重连（断开后保持等待手机状态）
  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final backoff = _reconnectAttempts >= 5 ? 30 : (1 << _reconnectAttempts);
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: backoff), () {
      if (_disposed) return;
      try {
        _socket?.connect();
      } catch (_) {}
    });
  }

  /// 手机加入后：为指定客户端创建 PeerConnection + 数据通道 + 发起 offer
  Future<void> createPeerConnectionAndOffer(String clientId,
      {String? deviceId, String? clientName, String? shareToken}) async {
    // 设备重连：替换旧会话
    await _closeSession(clientId);
    PeerSession? session = _sessions[clientId];
    if (session == null) {
      session = PeerSession(
        clientId: clientId,
        deviceId: deviceId ?? '',
        clientName: clientName ?? '手机',
        shareToken: shareToken,
      );
      _sessions[clientId] = session;
    } else {
      session.deviceId = deviceId ?? session.deviceId;
      session.clientName = clientName ?? session.clientName;
      session.shareToken = shareToken ?? session.shareToken;
    }

    final config = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        // 服务器下发的 TURN 中继（直连失败时兜底）
        if (turnConfig != null && turnConfig!['urls'] is List)
          for (final u in turnConfig!['urls'] as List)
            {
              'urls': u?.toString(),
              'username': turnConfig!['username']?.toString(),
              'credential': turnConfig!['credential']?.toString(),
            },
      ],
    };
    session.pc = await createPeerConnection(config);
    AppLog.i('host', 'PeerConnection 已创建($clientId), ICE服务器数=${config['iceServers']?.length ?? 0}');

    session.pc!.onIceCandidate = (candidate) {
      _sendSignal(clientId, {
        'type': 'candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    session.pc!.onConnectionState = (state) {
      onChannelState?.call(clientId,
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        // ICE 恢复：取消宽限计时，传输继续进行
        AppLog.i('host', 'ICE 状态: connected（恢复）[$clientId]');
        session?.cancelGraceTimer();
        // 连接建立/恢复后重新探测连接方式（直连 or 服务器中转），并周期复查
        detectConnectionType(clientId);
        _startConnProbe(clientId);
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // 短暂失联（网络抖动/WiFi断流/路由器重启）：宽限 45 秒，恢复则继续，否则判死。
        // 20 秒偏短：实测手机端 WiFi 断流约 20 秒未恢复即判死，导致大文件传一半中断
        AppLog.i('host', 'ICE 状态: disconnected（进入45秒宽限期）[$clientId]');
        session?.disconnectGraceTimer ??= Timer(const Duration(seconds: 45), () {
          AppLog.e('host', 'ICE 宽限期结束仍未恢复，判定断开 [$clientId]');
          session?.cancelGraceTimer();
          session?.cancelConnProbe();
          onPeerDisconnected?.call(clientId, session?.deviceId ?? '');
        });
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // failed 不代表连接已死：弱 WiFi 下 ICE 重试 15-30 秒即判 failed，
        // 此时立即判死会中断传输中的大文件。同样宽限 45 秒：恢复则继续
        AppLog.w('host', 'ICE 状态: failed（进入45秒宽限期）[$clientId]');
        session?.disconnectGraceTimer ??= Timer(const Duration(seconds: 45), () {
          AppLog.e('host', 'ICE failed 宽限期结束仍未恢复，判定断开 [$clientId]');
          session?.cancelGraceTimer();
          session?.cancelConnProbe();
          onPeerDisconnected?.call(clientId, session?.deviceId ?? '');
        });
      }
    };

    // Host 主动创建数据通道（手机端 onDataChannel 接收）
    session.channel = await session.pc!.createDataChannel('p2p', RTCDataChannelInit());
    AppLog.i('host', '数据通道已创建: p2p [$clientId]');
    _setupChannel(session);

    final offer = await session.pc!.createOffer();
    await session.pc!.setLocalDescription(offer);
    AppLog.i('host', '已创建并发送 offer [$clientId]');
    _sendSignal(clientId, {'type': 'offer', 'sdp': offer.sdp});
  }

  void _setupChannel(PeerSession session) {
    final clientId = session.clientId;
    session.channel!.onMessage = (message) {
      if (message.isBinary) {
        onData?.call(clientId, message.binary);
      } else {
        onData?.call(clientId, message.text);
      }
    };
    session.channel!.onDataChannelState = (state) {
      AppLog.i('host', '数据通道状态: $state [$clientId]');
      onChannelState?.call(clientId, state == RTCDataChannelState.RTCDataChannelOpen);
      // 数据通道打开后重新探测连接方式：ICE connected 触发探测时
      // 通道可能尚未打开而被跳过，需在通道就绪后再次探测
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        detectConnectionType(clientId);
      }
      // 数据通道关闭（对端断开）：通知上层进入等待状态
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        onPeerDisconnected?.call(clientId, session.deviceId);
      }
    };
  }

  void _handleSignal(String clientId, Map<String, dynamic> signal) async {
    final session = clientId.isNotEmpty ? _sessions[clientId] : null;
    if (session == null) {
      AppLog.w('host', '信令来自未知客户端: $clientId');
      return;
    }
    final pc = session.pc;
    if (pc == null) return;
    final type = signal['type'] as String?;
    switch (type) {
      case 'offer':
        // 手机端发起 ICE restart（网络切换）：电脑端生成 answer 配合重选路
        final offerSdp = signal['sdp'] as String?;
        if (offerSdp != null) {
          AppLog.i('host', '收到重新协商 offer，生成 answer [$clientId]');
          await pc.setRemoteDescription(
              RTCSessionDescription(offerSdp, 'offer'));
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          _sendSignal(clientId, {'type': 'answer', 'sdp': answer.sdp});
        }
        break;
      case 'answer':
        final sdp = signal['sdp'] as String?;
        if (sdp != null) {
          await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
        }
        break;
      case 'candidate':
        final c = signal['candidate'];
        if (c is Map) {
          await pc.addCandidate(RTCIceCandidate(
            c['candidate']?.toString(),
            c['sdpMid']?.toString(),
            c['sdpMLineIndex'] is int ? c['sdpMLineIndex'] as int : 0,
          ));
        }
        break;
      default:
        break;
    }
  }

  void _sendSignal(String clientId, Map<String, dynamic> signal) {
    AppLog.i('host', '发送信令: ${signal['type']} to=$clientId');
    _socket?.emit('signal:host→client', {'signal': signal, 'to': clientId});
  }

  /// 桌面绝对路径（我的电脑模式默认上传目录；取不到时返回空串）
  static String _desktopPath() {
    try {
      final profile = Platform.environment['USERPROFILE'] ?? '';
      if (profile.isEmpty) return '';
      final desktop = Directory('$profile\\Desktop');
      if (desktop.existsSync()) {
        return desktop.path.replaceAll('\\', '/');
      }
      final oneDrive = Platform.environment['OneDrive'] ?? '';
      if (oneDrive.isNotEmpty &&
          Directory('$oneDrive\\Desktop').existsSync()) {
        return '$oneDrive\\Desktop'.replaceAll('\\', '/');
      }
    } catch (_) {}
    return '';
  }

  /// 请求服务器重新生成配对码（旧码立即失效）
  void resetPairCode() {
    _socket?.emit('pair:reset');
  }

  /// 同步激活码到服务器（v5.9+）：生成/撤销后增量同步，幂等覆盖本机码表
  void syncActCodes(List<Map<String, String>> codes) {
    activationCodes = codes;
    if (!isConnected) return;
    _socket!.emit('host:sync-codes', {'codes': codes});
    AppLog.i('host', '激活码已同步服务器: ${codes.length} 个');
  }

  /// 全量同步共享配置到服务器（v5.0+）：创建/删除/改权限/启动注册后调用，
  /// 手机端激活后凭设备令牌拉取“共享给我的”列表，并免配对码连接共享所在电脑
  Future<Map<String, dynamic>> syncSharesToServer(
      List<Map<String, dynamic>> shares) async {
    try {
      if (_serverUrl.isEmpty) return {'ok': false, 'error': '未配置服务器'};
      final client = HttpClient();
      try {
        final req = await client
            .postUrl(Uri.parse('$_serverUrl/api/shares/sync'))
            .timeout(const Duration(seconds: 10));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({
          'deviceId': MachineId.get(),
          'hostToken': hostToken,
          'shares': shares,
        }));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        final body = await resp.transform(utf8.decoder).join();
        final result = jsonDecode(body);
        if (result is Map && result['ok'] == true) {
          AppLog.i('host', '共享已同步到服务器: ${shares.length} 条');
          return Map<String, dynamic>.from(result);
        }
        AppLog.w('host', '共享同步失败: ${resp.statusCode} $body');
        return {'ok': false, 'error': body};
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      AppLog.w('host', '共享同步异常', e);
      return {'ok': false, 'error': '$e'};
    }
  }

  /// 请求服务器踢出指定客户端（管理员功能）
  void kickClient(String clientId) {
    _socket?.emit('admin:kick', {'clientId': clientId});
  }

  // ── 数据发送（按客户端路由） ──────────────────────────────
  /// 发送 JSON 控制消息到指定手机端
  /// 发送 JSON 控制消息（await 发送完成：file-complete 等关键消息若静默
  /// 丢失，手机端无法收尾；曾因 fire-and-forget 导致发送失败无人感知）
  Future<void> sendJsonTo(String clientId, Map<String, dynamic> json) async {
    final ch = _sessions[clientId]?.channel;
    if (ch != null) {
      await ch.send(RTCDataChannelMessage(jsonEncode(json)));
    }
  }

  /// 发送二进制文件块（await 发送完成：底层缓冲满/通道关闭时 send 会
  /// 抛错，必须让发送循环感知——曾因不 await 导致数据静默丢失、
  /// 电脑端报“发送完成”而手机端收不全（1.75GB mkv 实测差 190 万字节））
  Future<void> sendBinaryTo(String clientId, Uint8List bytes) async {
    final ch = _sessions[clientId]?.channel;
    if (ch != null) {
      await ch.send(RTCDataChannelMessage.fromBinary(bytes));
    }
  }

  /// 发送前等待限速许可（按客户端各自的连接方式）
  Future<void> waitSendPermit(String clientId, int bytes) async {
    await _sessions[clientId]?.waitSendPermit(bytes);
  }

  /// 周期复查连接方式：首次探测失败/网络切换后自动重试，
  /// 避免连接类型一直停留在“探测中…”
  void _startConnProbe(String clientId) {
    final session = _sessions[clientId];
    if (session == null) return;
    session.cancelConnProbe();
    session.connProbeTimer =
        Timer.periodic(const Duration(seconds: 15), (_) {
      detectConnectionType(clientId);
    });
  }

  /// 探测指定客户端的连接方式（连接建立后调用）
  /// 严格判定：只认显式标记为选中/提名的候选对；字段缺失的候选对一律跳过
  /// （可能仍在 checking）；无选中对时不更新结果，等下一轮复查，避免误判
  Future<void> detectConnectionType(String clientId) async {
    final session = _sessions[clientId];
    if (session == null) return;
    final pc = session.pc;
    if (pc == null) return;
    try {
      // 等待 ICE 选路稳定后再读取统计，避免误判。
      // 1.2s 偏短：实测 ICE 刚 connected 时 selected/nominated 标记未就绪，
      // 容易误命中仍在 checking 的候选对（如 TURN relay 对），
      // 曾导致同一连接两端探测结果不一致（一端显示直连一端显示中转）
      await Future.delayed(const Duration(milliseconds: 2500));
      final cur = _sessions[clientId];
      if (cur == null || cur.pc != pc || !cur.isOpen) return;
      final reports = await pc.getStats();
      var type = 'direct';
      var foundSelected = false;
      for (final r in reports) {
        if (r.type != 'candidate-pair') continue;
        final selected = r.values['selected'];
        final nominated = r.values['nominated'];
        // 只有显式选中/提名的候选对才算当前路径；
        // selected/nominated 都缺失的对（可能仍在 checking）一律跳过
        final isSelected = (selected is bool && selected) ||
            (selected is int && selected == 1) ||
            (nominated is bool && nominated) ||
            (nominated is int && nominated == 1);
        final hasMark = selected != null || nominated != null;
        if (!hasMark || !isSelected) continue;
        foundSelected = true;
        final local = r.values['localCandidateType']?.toString();
        final remote = r.values['remoteCandidateType']?.toString();
        if (local == 'relay' || remote == 'relay') {
          type = 'relay';
          break;
        }
        // 兼容旧统计字段：通过候选 id 反查 candidateType
        final localId = r.values['localCandidateId']?.toString();
        final remoteId = r.values['remoteCandidateId']?.toString();
        var relayFound = false;
        for (final c in reports) {
          final isTarget = (c.id == localId || c.id == remoteId) &&
              (c.type == 'local-candidate' || c.type == 'remote-candidate');
          if (isTarget && c.values['candidateType'] == 'relay') {
            type = 'relay';
            relayFound = true;
            break;
          }
        }
        if (relayFound) break;
        break; // 已找到唯一选中的候选对且非 relay
      }
      // 未找到显式选中的候选对：ICE 选路尚未稳定，保持原结果等待下一轮复查。
      // 注意：不能用“存在 relay 候选痕迹”兑底判中转——TURN 凭证下发后 relay
      // 候选必然存在，有候选 ≠ 在用，兑底是误判“服务器中转”的根源
      if (!foundSelected) return;
      if (type != cur.connectionType) {
        cur.connectionType = type;
        cur.setRelayMode(type == 'relay');
        AppLog.i('conn',
            '[$clientId] 连接方式: ${type == 'relay' ? '服务器中转(TURN)' : 'P2P直连'}');
        onConnectionType?.call(clientId, type);
      }
    } catch (e) {
      AppLog.w('conn', '连接方式探测失败 [$clientId]', e);
    }
  }

  Future<void> _closeSession(String clientId) async {
    final session = _sessions.remove(clientId);
    if (session == null) return;
    session.cancelGraceTimer();
    session.cancelConnProbe();
    try {
      await session.channel?.close();
    } catch (_) {}
    session.channel = null;
    try {
      await session.pc?.close();
    } catch (_) {}
    session.pc = null;
  }

  /// 移除指定客户端会话（断开清理 / 管理员踢出时调用，幂等）
  Future<void> removeSession(String clientId) async {
    await _closeSession(clientId);
  }

  /// 主动离线：通知服务器删除本机会话（手机端立即收到“电脑离线”，
  /// 不再登记等待），随后断开 socket 且不自动重连
  Future<void> goOffline() async {
    try {
      _socket?.emit('host:offline');
    } catch (_) {}
    await dispose();
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopNetworkWatch();
    for (final cid in _sessions.keys.toList()) {
      await _closeSession(cid);
    }
    _sessions.clear();
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
  }
}
