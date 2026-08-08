import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC 数据通道服务：手机端作为应答方（电脑端发起 offer）
///
/// 信令格式与电脑端 simple-peer 兼容：
/// - offer/answer: { type, sdp }
/// - ICE candidate: { type: 'candidate', candidate: { candidate, sdpMid, sdpMLineIndex } }
class RtcService {
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;

  /// 收到的原始数据（String 或 Uint8List）
  final _messageController = StreamController<dynamic>.broadcast();
  Stream<dynamic> get messages => _messageController.stream;

  /// 数据通道连接状态变化
  final _stateController = StreamController<bool>.broadcast();
  Stream<bool> get stateChanges => _stateController.stream;

  /// 发送 WebRTC 信令到电脑端（由外部注入）
  void Function(Map<String, dynamic> signal)? sendSignal;

  /// TURN 中继凭证（由配对消息携带，创建 PeerConnection 前设置）
  Map<String, dynamic>? turnConfig;

  bool get isOpen => _channel?.state == RTCDataChannelState.RTCDataChannelOpen;

  int get bufferedAmount => _channel?.bufferedAmount ?? 0;

  /// 清理旧连接；PeerConnection 推迟到收到 offer 时创建
  /// （此时配对消息已到达，TURN 凭证必然已就绪）
  Future<void> init() async {
    await dispose();
    _pcReady = null;
  }

  Future<void>? _pcReady;

  Future<void> _ensurePc() => _pcReady ??= _doInit();

  Future<void> _doInit() async {
    // flutter_webrtc 1.6+：配置使用 Map 形式
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
    _pc!.onDataChannel = (channel) => _setupChannel(channel);
    _pc!.onIceCandidate = (candidate) {
      sendSignal?.call({
        'type': 'candidate',
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };
    _pc!.onConnectionState = (state) {
      final open =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      _stateController.add(open);
    };
  }

  void _setupChannel(RTCDataChannel channel) {
    _channel = channel;
    channel.onMessage = (message) {
      if (message.isBinary) {
        _messageController.add(message.binary);
      } else {
        _messageController.add(message.text);
      }
    };
    channel.onDataChannelState = (state) {
      _stateController.add(
          state == RTCDataChannelState.RTCDataChannelOpen);
    };
  }

  /// 处理来自电脑端的信令
  Future<void> handleSignal(Map<String, dynamic> signal) async {
    await _ensurePc(); // 首次收到信令（offer/candidate）时创建 PeerConnection
    final pc = _pc;
    if (pc == null) return;

    final type = signal['type'] as String?;
    switch (type) {
      case 'offer':
        final sdp = signal['sdp'] as String?;
        if (sdp == null) return;
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        sendSignal?.call({'type': 'answer', 'sdp': answer.sdp});
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

  /// 发送 JSON 控制消息
  void sendJson(Map<String, dynamic> json) {
    _channel?.send(RTCDataChannelMessage(jsonEncode(json)));
  }

  /// 发送二进制文件块
  void sendBinary(Uint8List bytes) {
    _channel?.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Future<void> dispose() async {
    try {
      await _channel?.close();
    } catch (_) {}
    _channel = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
  }
}
