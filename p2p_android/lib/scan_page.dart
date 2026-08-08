import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码配对结果
class ScanPairResult {
  final String server;
  final String code;

  const ScanPairResult(this.server, this.code);
}

/// 配对码格式：10 位数字/字母
final RegExp kPairCodeRegExp = RegExp(r'^[A-Za-z0-9]{10}$');

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
    if (result == null) return;
    _handled = true;
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(result);
  }

  /// 解析 `p2p:<server>|<code>`，失败返回 null
  ScanPairResult? _parse(String raw) {
    final body = raw.substring(4);
    final sep = body.lastIndexOf('|');
    if (sep <= 0 || sep == body.length - 1) return null;
    final server = body.substring(0, sep).trim();
    final code = body.substring(sep + 1).trim();
    if (!server.startsWith('http://') && !server.startsWith('https://')) {
      return null;
    }
    if (!kPairCodeRegExp.hasMatch(code)) return null;
    return ScanPairResult(server, code);
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
