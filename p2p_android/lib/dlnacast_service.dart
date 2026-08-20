import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// DLNA 投屏设备（MediaRenderer 接收端：电视/盒子/投影仪）
class CastDevice {
  /// 设备名（friendlyName）
  final String name;

  /// AVTransport 控制 URL（绝对地址）
  final Uri controlUrl;

  /// 设备描述 URL（日志/定位用）
  final Uri location;

  const CastDevice({
    required this.name,
    required this.controlUrl,
    required this.location,
  });
}

/// DLNA 投屏服务（v5.33+，纯 Dart 实现，零第三方依赖）：
/// - discover: SSDP M-SEARCH 组播发现局域网 MediaRenderer 接收端
/// - SOAP 控制：SetAVTransportURI / Play / Pause / Stop / Seek / GetPositionInfo
class DlnaCastService {
  static const String _ssdpAddr = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const String _avTransport =
      'urn:schemas-upnp-org:service:AVTransport:1';

  /// 发现局域网 DLNA 接收端设备列表（timeout 内收集并解析设备描述）
  Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final results = <String, CastDevice>{};
    final pending = <Future<void>>[];
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, _ssdpPort,
          reuseAddress: true, reusePort: true);
    } catch (e) {
      // 1900 端口被占（如系统其他服务）：退化为随机端口（响应仍单播可达）
      AppLog.w('cast', 'SSDP 1900 端口绑定失败，改用随机端口', e);
      try {
        socket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4, 0,
            reuseAddress: true, reusePort: true);
      } catch (e2) {
        AppLog.e('cast', 'SSDP 绑定失败', e2);
        return const [];
      }
    }
    final sock = socket;
    // 组播 M-SEARCH 发现请求（响应为单播，无需 MulticastLock 即可接收）
    final search = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddr:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
        '\r\n';
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      final text = utf8.decode(dg.data, allowMalformed: true);
      if (!text.contains('200 OK')) return;
      final loc = RegExp(r'LOCATION:\s*(\S+)', caseSensitive: false)
          .firstMatch(text)
          ?.group(1);
      if (loc == null) return;
      final location = Uri.tryParse(loc);
      if (location == null || location.host.isEmpty) return;
      final usn = RegExp(r'USN:\s*(\S+)', caseSensitive: false)
              .firstMatch(text)
              ?.group(1) ??
          '${location.host}:${location.port}';
      if (results.containsKey(usn)) return;
      // 异步解析设备描述（friendlyName + AVTransport 控制地址）
      pending.add(_resolveDevice(location).then((d) {
        if (d != null) results[usn] = d;
      }).catchError((e) {
        AppLog.w('cast', '解析设备描述失败: $location $e');
      }));
    });
    sock.send(utf8.encode(search), InternetAddress(_ssdpAddr), _ssdpPort);

    await Future.delayed(timeout);
    await Future.wait(pending);
    sock.close();
    AppLog.i('cast', '发现 DLNA 设备 ${results.length} 个: '
        '${results.values.map((d) => d.name).join(', ')}');
    return results.values.toList();
  }

  /// 解析设备描述 XML：取 friendlyName 与 AVTransport 控制 URL
  Future<CastDevice?> _resolveDevice(Uri location) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(location);
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final xml = await res.transform(utf8.decoder).join();
      final name = _xmlField(xml, 'friendlyName') ?? location.host;
      // 遍历 serviceList 找 AVTransport 服务的 controlURL
      Uri? control;
      for (final m in RegExp(r'<service>([\s\S]*?)</service>',
              caseSensitive: false)
          .allMatches(xml)) {
        final svc = m.group(1) ?? '';
        if (!svc.contains('AVTransport')) continue;
        final ctrl = _xmlField(svc, 'controlURL');
        if (ctrl == null) continue;
        control = location.resolve(ctrl);
        break;
      }
      if (control == null) return null; // 无 AVTransport 服务：非接收端
      return CastDevice(
        name: name,
        controlUrl: control,
        location: location,
      );
    } catch (e) {
      AppLog.w('cast', '设备描述请求异常: $location $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 从 XML 提取单个字段文本（兼容 CDATA 与换行）
  String? _xmlField(String xml, String tag) {
    final m = RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(xml);
    if (m == null) return null;
    var v = m.group(1)!.trim();
    v = v.replaceAll(RegExp(r'^<!\[CDATA\[|\]\]>$'), '');
    return v.trim().isEmpty ? null : v;
  }

  // ─────────── SOAP 控制 ───────────

  Future<bool> _soap(CastDevice d, String action, String body) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(d.controlUrl);
      req.headers.contentType =
          ContentType('text', 'xml', parameters: {'charset': 'utf-8'});
      req.headers.set('SOAPAction', '"$_avTransport#$action"');
      final xml = '<?xml version="1.0" encoding="utf-8"?>\r\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          '<s:Body>$body</s:Body></s:Envelope>';
      req.write(xml);
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await res.transform(utf8.decoder).join();
      final ok = res.statusCode == 200;
      if (!ok) {
        AppLog.w('cast', 'SOAP $action 失败: ${res.statusCode} '
            '${_xmlField(text, 'errorDescription') ?? ''}');
      }
      return ok;
    } catch (e) {
      AppLog.w('cast', 'SOAP $action 请求异常: $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// 设置播放源（投流地址），成功后电视就绪待播放
  Future<bool> setAvTransportUri(CastDevice d, String url) {
    final escaped = url.replaceAll('&', '&amp;').replaceAll('<', '&lt;');
    return _soap(d, 'SetAVTransportURI',
        '<u:SetAVTransportURI xmlns:u="$_avTransport">'
        '<InstanceID>0</InstanceID>'
        '<CurrentURI>$escaped</CurrentURI>'
        '<CurrentURIMetaData></CurrentURIMetaData>'
        '</u:SetAVTransportURI>');
  }

  Future<bool> play(CastDevice d) => _soap(d, 'Play',
      '<u:Play xmlns:u="$_avTransport">'
      '<InstanceID>0</InstanceID><Speed>1</Speed></u:Play>');

  Future<bool> pause(CastDevice d) => _soap(d, 'Pause',
      '<u:Pause xmlns:u="$_avTransport"><InstanceID>0</InstanceID></u:Pause>');

  Future<bool> stop(CastDevice d) => _soap(d, 'Stop',
      '<u:Stop xmlns:u="$_avTransport"><InstanceID>0</InstanceID></u:Stop>');

  Future<bool> seek(CastDevice d, Duration pos) {
    final t = '${pos.inHours.toString().padLeft(2, '0')}:'
        '${(pos.inMinutes % 60).toString().padLeft(2, '0')}:'
        '${(pos.inSeconds % 60).toString().padLeft(2, '0')}';
    return _soap(d, 'Seek',
        '<u:Seek xmlns:u="$_avTransport"><InstanceID>0</InstanceID>'
        '<Unit>REL_TIME</Unit><Target>$t</Target></u:Seek>');
  }

  /// 查询播放位置/时长/播放状态（遥控器进度同步用）
  Future<(Duration?, Duration?, bool)> getPositionInfo(CastDevice d) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(d.controlUrl);
      req.headers.contentType =
          ContentType('text', 'xml', parameters: {'charset': 'utf-8'});
      req.headers.set('SOAPAction', '"$_avTransport#GetPositionInfo"');
      req.write('<?xml version="1.0" encoding="utf-8"?>\r\n'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          '<s:Body><u:GetPositionInfo xmlns:u="$_avTransport">'
          '<InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return (null, null, false);
      Duration? parseDur(String? v) {
        if (v == null) return null;
        final m = RegExp(r'(\d+):(\d+):(\d+)').firstMatch(v);
        if (m == null) return null;
        return Duration(
          hours: int.parse(m.group(1)!),
          minutes: int.parse(m.group(2)!),
          seconds: int.parse(m.group(3)!),
        );
      }

      final rel = _xmlField(text, 'RelTime');
      final dur = _xmlField(text, 'TrackDuration');
      final state = _xmlField(text, 'TransportState')?.toUpperCase();
      return (parseDur(rel), parseDur(dur), state == 'PLAYING');
    } catch (e) {
      AppLog.w('cast', 'GetPositionInfo 异常: $e');
      return (null, null, false);
    } finally {
      client.close();
    }
  }
}
