import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

/// 信令服务：与 p2p-app/server.js 的 Socket.IO 事件完全兼容
class SignalingService {
  io.Socket? _socket;
  bool _disposed = false;

  /// 配对成功（收到电脑端信息）
  void Function(Map<String, dynamic> hostInfo)? onJoined;

  /// 配对失败（reason 为用户可读提示）
  void Function(String reason)? onError;

  /// 服务器下发的 TURN 中继凭证（client:joined 携带，可能为 null）
  Map<String, dynamic>? turnConfig;

  /// 收到 WebRTC 信令（SDP / ICE）
  void Function(Map<String, dynamic> signal)? onSignal;

  /// 对端（电脑端）断开
  void Function()? onPeerDisconnected;

  /// 连接服务器失败
  void Function(String message)? onConnectError;

  bool get isConnected => _socket?.connected ?? false;

  /// 连接信令服务器并加入配对
  Future<void> connect({
    required String serverUrl,
    required String pairCode,
    required String deviceName,
  }) async {
    _socket?.dispose();
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      _socket!.emit('client:join', {
        'pairCode': pairCode,
        'deviceName': deviceName,
      });
    });

    _socket!.on('client:joined', (data) {
      if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        final turn = map['turn'];
        turnConfig = turn is Map
            ? Map<String, dynamic>.from(turn)
            : null;
        onJoined?.call(map);
      }
    });

    _socket!.on('client:error', (data) {
      final reason =
          data is Map ? data['reason']?.toString() ?? '配对失败' : '配对失败';
      onError?.call(reason);
    });

    _socket!.on('signal:server→client', (data) {
      if (data is Map && data['signal'] is Map) {
        onSignal?.call(Map<String, dynamic>.from(data['signal'] as Map));
      }
    });

    _socket!.on('peer:disconnected', (_) => onPeerDisconnected?.call());

    _socket!.onConnectError((data) {
      onConnectError?.call(data.toString());
    });

    _socket!.onDisconnect((_) {
      if (!_disposed) onPeerDisconnected?.call();
    });

    _socket!.connect();
  }

  /// 发送 WebRTC 信令到电脑端
  void sendSignal(Map<String, dynamic> signal) {
    _socket?.emit('signal:client→host', {'signal': signal});
  }

  /// 断开连接
  void dispose() {
    _disposed = true;
    _socket?.dispose();
    _socket = null;
  }
}
