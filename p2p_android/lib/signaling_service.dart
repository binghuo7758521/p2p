import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'app_log.dart';
import 'version.dart';

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
    String deviceId = '',
    String? shareToken,
    String? phone,
  }) async {
    AppLog.i('signal', '连接信令服务器: $serverUrl code=$pairCode'
        '${shareToken != null ? ' share=$shareToken' : ''}'
        '${phone != null ? ' phone=$phone' : ''}');
    _socket?.dispose();
    _socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      AppLog.i('signal', '服务器已连接 (id=${_socket!.id})，发送 client:join');
      _socket!.emit('client:join', {
        'pairCode': pairCode,
        'deviceName': deviceName,
        // 版本号：服务器配对日志记录客户端版本，便于排查版本差异问题
        'version': appVersion,
        // 设备唯一标识（多用户身份）、登录手机号与共享码（普通用户扫码加入）
        if (deviceId.isNotEmpty) 'deviceId': deviceId,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (shareToken != null && shareToken.isNotEmpty)
          'shareToken': shareToken,
      });
    });

    // Socket.IO 自动重连事件（网络抖动时排查用）
    _socket!.onReconnectAttempt((attempt) {
      AppLog.i('signal', 'Socket.IO 自动重连尝试 #$attempt');
    });
    _socket!.onReconnect((attempt) {
      AppLog.i('signal', 'Socket.IO 重连成功 (第$attempt次尝试)');
    });

    _socket!.on('client:joined', (data) {
      AppLog.i('signal', '收到 client:joined (配对成功)');
      if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        final turn = map['turn'];
        turnConfig = turn is Map
            ? Map<String, dynamic>.from(turn)
            : null;
        final hostInfo = map['hostInfo'];
        AppLog.i('signal',
            '配对详情: 主机=${hostInfo is Map ? hostInfo['name'] : map['name']}, '
            'TURN=${turn is Map ? '已下发(urls=${(turn['urls'] as List?)?.length ?? 0})' : '未配置'}');
        onJoined?.call(map);
      } else {
        AppLog.w('signal', 'client:joined 数据格式异常: $data');
      }
    });

    _socket!.on('client:error', (data) {
      final reason =
          data is Map ? data['reason']?.toString() ?? '配对失败' : '配对失败';
      AppLog.i('signal', '收到 client:error: $reason');
      onError?.call(reason);
    });

    _socket!.on('signal:server→client', (data) {
      if (data is Map && data['signal'] is Map) {
        final signal = Map<String, dynamic>.from(data['signal'] as Map);
        AppLog.i('signal', '收到信令: ${signal['type']}');
        onSignal?.call(signal);
      }
    });

    _socket!.on('peer:disconnected', (_) {
      AppLog.i('signal', '收到 peer:disconnected');
      onPeerDisconnected?.call();
    });

    _socket!.onConnectError((data) {
      AppLog.e('signal', '连接服务器失败', data.toString());
      onConnectError?.call(data.toString());
    });

    _socket!.onDisconnect((_) {
      AppLog.i('signal', '信令连接断开 (disposed=$_disposed)');
      if (!_disposed) onPeerDisconnected?.call();
    });

    _socket!.connect();
  }

  /// 发送 WebRTC 信令到电脑端
  void sendSignal(Map<String, dynamic> signal) {
    AppLog.i('signal', '发送信令: ${signal['type']}');
    _socket?.emit('signal:client→host', {'signal': signal});
  }

  /// 断开连接
  void dispose() {
    _disposed = true;
    _socket?.dispose();
    _socket = null;
  }
}
