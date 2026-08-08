import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// 电脑端 Host 服务：信令注册 + WebRTC 发起方（offerer）+ 数据通道
///
/// 与 p2p-app/server.js 和手机端 (flutter_webrtc answerer) 完全兼容：
/// - 注册: host:register → host:registered {pairCode}
/// - 手机加入: host:client-joined {clientInfo} → 发起 offer
/// - 信令: signal:host→client / signal:server→host
/// - 数据通道由本端主动创建（手机端通过 onDataChannel 接收）
class HostService {
  io.Socket? _socket;
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;

  // ── 自动重连（socket 断线后保持注册状态，等待手机重新加入） ──
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  // ── 对外回调 ────────────────────────────────────────────
  void Function(String pairCode)? onRegistered;
  void Function(Map<String, dynamic> clientInfo)? onClientJoined;
  void Function()? onPeerDisconnected;
  void Function(String reason)? onError;
  void Function(dynamic data)? onData; // 原始消息（String 或 Uint8List）
  void Function(bool open)? onChannelState;
  void Function(String pairCode)? onPairCodeChanged; // 配对码被重新生成

  bool get isConnected => _socket?.connected ?? false;
  bool get isOpen => _channel?.state == RTCDataChannelState.RTCDataChannelOpen;
  int get bufferedAmount => _channel?.bufferedAmount ?? 0;

  /// TURN 中继凭证（由 host:client-joined 携带，创建 PeerConnection 前设置）
  Map<String, dynamic>? turnConfig;

  /// 连接信令服务器并注册为主机
  Future<void> connect(String serverUrl) async {
    await dispose();
    _disposed = false;
    _reconnectAttempts = 0;
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      _reconnectAttempts = 0;
      _socket!.emit('host:register', {
        'deviceName': '电脑-桌面',
      });
    });

    _socket!.on('host:registered', (data) {
      if (data is Map) {
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
      onClientJoined?.call(
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{});
    });

    _socket!.on('signal:server→host', (data) {
      if (data is Map && data['signal'] is Map) {
        _handleSignal(Map<String, dynamic>.from(data['signal'] as Map));
      }
    });

    _socket!.on('peer:disconnected', (_) {
      onPeerDisconnected?.call();
    });

    _socket!.on('connect_error', (e) {
      onError?.call('无法连接信令服务器: $e');
    });

    // socket 断线：自动重连（指数退避 1s→30s），重连后自动重新注册
    _socket!.onDisconnect((_) {
      _scheduleReconnect();
    });

    _socket!.connect();
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

  /// 手机加入后：创建 PeerConnection + 数据通道 + 发起 offer
  Future<void> createPeerConnectionAndOffer() async {
    await _closePc();

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
    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (candidate) {
      _sendSignal({
        'type': 'candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    _pc!.onConnectionState = (state) {
      onChannelState?.call(
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      // WebRTC 层断开（如手机端断网/杀后台但 socket 仍存活）：通知上层进入等待状态
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onPeerDisconnected?.call();
      }
    };

    // Host 主动创建数据通道（手机端 onDataChannel 接收）
    _channel = await _pc!.createDataChannel('p2p', RTCDataChannelInit());
    _setupChannel(_channel!);

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    _sendSignal({'type': 'offer', 'sdp': offer.sdp});
  }

  void _setupChannel(RTCDataChannel channel) {
    channel.onMessage = (message) {
      if (message.isBinary) {
        onData?.call(message.binary);
      } else {
        onData?.call(message.text);
      }
    };
    channel.onDataChannelState = (state) {
      onChannelState
          ?.call(state == RTCDataChannelState.RTCDataChannelOpen);
      // 数据通道关闭（对端断开）：通知上层进入等待状态
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        onPeerDisconnected?.call();
      }
    };
  }

  void _handleSignal(Map<String, dynamic> signal) async {
    final pc = _pc;
    if (pc == null) return;
    final type = signal['type'] as String?;
    switch (type) {
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

  void _sendSignal(Map<String, dynamic> signal) {
    _socket?.emit('signal:host→client', {'signal': signal});
  }

  /// 请求服务器重新生成配对码（旧码立即失效）
  void resetPairCode() {
    _socket?.emit('pair:reset');
  }

  /// 发送 JSON 控制消息
  void sendJson(Map<String, dynamic> json) {
    _channel?.send(RTCDataChannelMessage(jsonEncode(json)));
  }

  /// 发送二进制文件块
  void sendBinary(Uint8List bytes) {
    _channel?.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Future<void> _closePc() async {
    try {
      await _channel?.close();
    } catch (_) {}
    _channel = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closePc();
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
  }
}
