import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_log.dart';

/// 发送限速器（令牌桶）：仅服务器中转(relay)时启用，P2P 直连不限速
class SendRateLimiter {
  final double rate; // 字节/秒
  double _tokens;
  int _lastMs;

  SendRateLimiter(this.rate)
      : _tokens = 0, // 初始空桶：限速立即生效（满桶会导致前 1 秒不限速）
        _lastMs = DateTime.now().millisecondsSinceEpoch;

  /// 申请发送 [bytes] 字节，速率不足时按需等待（桶容量=1秒量，稳态精确限速）
  Future<void> acquire(int bytes) async {
    while (true) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final elapsed = now - _lastMs;
      _lastMs = now;
      _tokens = (_tokens + rate * elapsed / 1000).clamp(0.0, rate);
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

  /// 当前连接方式：direct=直连 / relay=服务器中转(TURN) / unknown=未知
  String connectionType = 'unknown';

  /// 连接方式探测完成回调（'direct' / 'relay'）
  void Function(String type)? onConnectionType;

  /// 服务器中转时的最大发送速率：500KB/s
  static const double relayMaxRate = 500 * 1024;

  SendRateLimiter? _rateLimiter;

  /// 周期探测定时器：连接期间每 15s 复查一次连接方式，
  /// 避免首次探测失败/网络切换后一直停留在“探测中…”
  Timer? _connProbeTimer;

  void _startConnProbe() {
    _connProbeTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (!isOpen) {
        _stopConnProbe();
        return;
      }
      detectConnectionType();
    });
  }

  void _stopConnProbe() {
    _connProbeTimer?.cancel();
    _connProbeTimer = null;
  }

  /// 根据连接方式启停发送限速（仅服务器中转限速，直连不限速）
  void setRelayMode(bool relay) {
    _rateLimiter = relay ? SendRateLimiter(relayMaxRate) : null;
    AppLog.i('conn', relay ? '服务器中转：发送限速 500KB/s 已启用' : 'P2P 直连：发送不限速');
  }

  /// 发送前调用：等待限速许可（直连/未探测时立即放行）
  Future<void> waitSendPermit(int bytes) async {
    await _rateLimiter?.acquire(bytes);
  }

  /// 探测当前连接方式（连接建立后调用；relay=服务器中转，其余=直连）
  /// 严格判定：只认显式标记为选中/提名的候选对；字段缺失的候选对一律跳过
  /// （可能仍在 checking）；无选中对时不更新结果，等下一轮复查，避免误判
  Future<void> detectConnectionType() async {
    final pc = _pc;
    if (pc == null || !isOpen) return;
    try {
      // 等待 ICE 选路稳定后再读取统计，避免误判。
      // 1.2s 偏短：实测 ICE 刚 connected 时 selected/nominated 标记未就绪，
      // 容易误命中仍在 checking 的候选对（如 TURN relay 对），
      // 曾导致同一连接两端探测结果不一致（一端显示直连一端显示中转）
      await Future.delayed(const Duration(milliseconds: 2500));
      if (_pc != pc || !isOpen) return;
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
        var relayInPair = false;
        for (final c in reports) {
          final isTarget = (c.id == localId || c.id == remoteId) &&
              (c.type == 'local-candidate' || c.type == 'remote-candidate');
          if (isTarget && c.values['candidateType'] == 'relay') {
            relayInPair = true;
            break;
          }
        }
        if (relayInPair) {
          type = 'relay';
        }
        break; // 已找到唯一选中的候选对
      }
      // 未找到显式选中的候选对：ICE 选路尚未稳定，保持原结果等待下一轮复查。
      // 注意：不能用“存在 relay 候选痕迹”兑底判中转——TURN 凭证下发后 relay
      // 候选必然存在，有候选 ≠ 在用，兑底是误判“服务器中转”的根源
      if (!foundSelected) return;
      if (type != connectionType) {
        connectionType = type;
        setRelayMode(type == 'relay');
        AppLog.i('conn',
            '连接方式: ${type == 'relay' ? '服务器中转(TURN)' : 'P2P直连'}');
        onConnectionType?.call(type);
      }
    } catch (e) {
      AppLog.w('conn', '连接方式探测失败', e);
    }
  }

  /// 发送 WebRTC 信令到电脑端（由外部注入）
  void Function(Map<String, dynamic> signal)? sendSignal;

  /// TURN 中继凭证（由配对消息携带，创建 PeerConnection 前设置）
  Map<String, dynamic>? turnConfig;

  // ICE 短暂失联宽限期：Disconnected 后等待恢复，避免网络抖动导致传输中断
  Timer? _disconnectGraceTimer;

  bool get isOpen => _channel?.state == RTCDataChannelState.RTCDataChannelOpen;

  int get bufferedAmount => _channel?.bufferedAmount ?? 0;

  /// 清理旧连接；PeerConnection 推迟到收到 offer 时创建
  /// （此时配对消息已到达，TURN 凭证必然已就绪）
  Future<void> init() async {
    AppLog.i('rtc', 'RTC init（清理旧连接）');
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
    AppLog.i('rtc', 'PeerConnection 已创建, ICE服务器数=${config['iceServers']?.length ?? 0}');
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
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        // ICE 恢复：取消宽限计时，传输继续进行
        AppLog.i('rtc', 'ICE 状态: connected（恢复）');
        _disconnectGraceTimer?.cancel();
        _disconnectGraceTimer = null;
        _stateController.add(true);
        // 连接建立/恢复后重新探测连接方式（直连 or 服务器中转），并周期复查
        detectConnectionType();
        _startConnProbe();
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // 短暂失联（网络抖动/WiFi断流/路由器重启）：宽限 45 秒，恢复则继续，否则判死。
        // 直接判死会让传输中的大文件瞬间中断；WiFi 断流通常 30 秒内恢复，
        // 20 秒仍偏短（实测 20 秒宽限期内未恢复即判死导致大文件传一半中断）
        AppLog.i('rtc', 'ICE 状态: disconnected（进入45秒宽限期）');
        _disconnectGraceTimer ??= Timer(const Duration(seconds: 45), () {
          AppLog.e('rtc', 'ICE 宽限期结束仍未恢复，判定断开');
          _disconnectGraceTimer = null;
          _stopConnProbe();
          _stateController.add(false);
        });
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // failed 不代表连接已死：弱 WiFi 下 ICE 重试 15-30 秒即判 failed，
        // 此时立即判死会中断传输中的大文件（实测 18:20/18:22 两次中断均因此触发）。
        // 同样进入 45 秒宽限期：期间恢复则继续，否则判死重连
        AppLog.w('rtc', 'ICE 状态: failed（进入45秒宽限期）');
        _disconnectGraceTimer ??= Timer(const Duration(seconds: 45), () {
          AppLog.e('rtc', 'ICE failed 宽限期结束仍未恢复，判定断开');
          _disconnectGraceTimer = null;
          _stopConnProbe();
          _stateController.add(false);
        });
      }
    };
  }

  void _setupChannel(RTCDataChannel channel) {
    _channel = channel;
    AppLog.i('rtc', '数据通道已建立: ${channel.label}');
    channel.onMessage = (message) {
      if (message.isBinary) {
        _messageController.add(message.binary);
      } else {
        _messageController.add(message.text);
      }
    };
    channel.onDataChannelState = (state) {
      AppLog.i('rtc', '数据通道状态: $state');
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
        AppLog.i('rtc', '收到 offer，生成 answer (sdp长度=${sdp?.length ?? 0})');
        if (sdp == null) {
          AppLog.w('rtc', 'offer 缺少 sdp 字段，忽略');
          return;
        }
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        sendSignal?.call({'type': 'answer', 'sdp': answer.sdp});
        AppLog.i('rtc', 'answer 已生成并发送 (sdp长度=${answer.sdp?.length ?? 0})');
        break;

      case 'candidate':
        final c = signal['candidate'];
        if (c is Map) {
          await pc.addCandidate(RTCIceCandidate(
            c['candidate']?.toString(),
            c['sdpMid']?.toString(),
            c['sdpMLineIndex'] is int ? c['sdpMLineIndex'] as int : 0,
          ));
        } else {
          AppLog.w('rtc', 'candidate 信令格式异常: $c');
        }
        break;

      default:
        AppLog.w('rtc', '收到未知信令类型: $type');
        break;
    }
  }

  /// 发送 JSON 控制消息（记录类型与关键字段，便于协议排障）
  void sendJson(Map<String, dynamic> json) {
    final type = json['type'] ?? '?';
    final logFields = <String>[];
    const whitelist = ['fileName', 'fileSize', 'path', 'subPath', 'requestId', 'offset', 'success', 'reason', 'action'];
    for (final k in whitelist) {
      if (json[k] != null) logFields.add('$k=${json[k]}');
    }
    AppLog.i('send', '发送控制消息: $type ${logFields.join(' ')}');
    _channel?.send(RTCDataChannelMessage(jsonEncode(json)));
  }

  /// 发送二进制文件块
  void sendBinary(Uint8List bytes) {
    _channel?.send(RTCDataChannelMessage.fromBinary(bytes));
  }

  Future<void> dispose() async {
    AppLog.i('rtc', 'RTC dispose（清理连接）');
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    _stopConnProbe();
    connectionType = 'unknown';
    _rateLimiter = null;
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
