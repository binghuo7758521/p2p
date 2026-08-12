import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'app_log.dart';

/// 扫码结果：配对码 或 共享码
class ScanPairResult {
  final String server;
  final String code;
  final String? shareToken; // 共享码（扫共享二维码时非空）

  const ScanPairResult(this.server, this.code, [this.shareToken]);
}

/// 配对码格式：10 位数字/字母
final RegExp kPairCodeRegExp = RegExp(r'^[A-Za-z0-9]{10}$');

/// 共享码格式：8 位数字/字母
final RegExp kShareTokenRegExp = RegExp(r'^[A-Za-z0-9]{8}$');

/// 扫码配对页：扫描电脑端二维码，自动获取服务器地址与配对码
///
/// 二维码内容格式：`p2p:<服务器地址>|<10位配对码>`
/// 例：`p2p:http://182.92.157.93:3000|AB3CDE789X`
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  bool _error = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    if (capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null || !raw.startsWith('p2p:')) return;

    final result = _parse(raw);
    if (result == null) {
      AppLog.w('scan', '二维码内容格式异常: ${raw.length > 80 ? '${raw.substring(0, 80)}…' : raw}');
      return;
    }
    _handled = true;
    AppLog.i('scan', '扫码成功: server=${result.server}');
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(result);
  }

  /// 解析 `p2p:<server>|<code>[|<shareToken>]`，失败返回 null
  ScanPairResult? _parse(String raw) {
    final body = raw.substring(4);
    final parts = body.split('|');
    if (parts.length < 2 || parts.length > 3) return null;
    final server = parts[0].trim();
    final code = parts[1].trim();
    if (!server.startsWith('http://') && !server.startsWith('https://')) {
      return null;
    }
    if (!kPairCodeRegExp.hasMatch(code)) return null;
    String? shareToken;
    if (parts.length == 3) {
      shareToken = parts[2].trim();
      if (!kShareTokenRegExp.hasMatch(shareToken)) return null;
    }
    return ScanPairResult(server, code, shareToken);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫描电脑端二维码'),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            onDetectError: (_, _) {
              if (!mounted) return;
              setState(() => _error = true);
            },
          ),
          // 扫描框引导
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error)
                    const Text('相机不可用，请检查相机权限',
                        style: TextStyle(color: Colors.redAccent)),
                  const Text(
                    '将二维码放入框内即可自动识别',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '二维码由电脑端软件在配对码下方显示',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
