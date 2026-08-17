import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'activate_page.dart' show kActCodeRegExp;
import 'app_log.dart';

/// 激活码扫码页（v5.18+ 双格式通用入口）：扫描电脑端展示的
/// 激活码二维码（成为管理员）或共享二维码（自动激活共享访客）。
///
/// 二维码内容格式：
/// - 激活码：`p2p-act:<服务器地址>|<8位激活码>`（v5.16+）
///   兼容旧格式 `p2p-act:<码>` 与纯 8 位激活码（使用默认服务器）
/// - 共享码：`p2p:<服务器地址>|<10位配对码>|<共享码>`（v5.18+）
///   扫码即自动激活共享访客并连接该共享
class ActivateScanPage extends StatefulWidget {
  const ActivateScanPage({super.key});

  @override
  State<ActivateScanPage> createState() => _ActivateScanPageState();
}

class _ActivateScanPageState extends State<ActivateScanPage> {
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
    if (raw == null) return;

    final result = _parse(raw);
    if (result == null) {
      AppLog.w('scan',
          '二维码内容非激活码/共享码: ${raw.length > 80 ? '${raw.substring(0, 80)}…' : raw}');
      return;
    }
    _handled = true;
    AppLog.i('scan',
        '扫码成功: ${result.kind == 'act' ? '激活码=${result.code}' : '共享码=${result.shareToken?.substring(0, 4)}…'} server=${result.server ?? '默认'}');
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(result);
  }

  /// 解析激活码（`p2p-act:<server>|<码>` / `p2p-act:<码>` / 纯 8 位码）
  /// 与共享码（`p2p:<server>|<配对码>|<共享码>`，v5.18+），失败返回 null
  ScanResult? _parse(String raw) {
    if (raw.startsWith('p2p-act:')) {
      final parts = raw.substring(8).split('|');
      if (parts.length == 2) {
        final server = parts[0].trim();
        final code = parts[1].trim().toUpperCase();
        if ((server.startsWith('http://') || server.startsWith('https://')) &&
            kActCodeRegExp.hasMatch(code)) {
          return ScanResult.act(server: server, code: code);
        }
        return null;
      }
      if (parts.length == 1) {
        final code = parts[0].trim().toUpperCase();
        return kActCodeRegExp.hasMatch(code)
            ? ScanResult.act(code: code)
            : null;
      }
      return null;
    }
    if (raw.startsWith('p2p:')) {
      // 共享码：p2p:<server>|<10位配对码>|<共享码>（v5.18+ 自动激活访客）
      final parts = raw.substring(4).split('|');
      if (parts.length == 3) {
        final server = parts[0].trim();
        final pairCode = parts[1].trim().toUpperCase();
        final shareToken = parts[2].trim();
        if ((server.startsWith('http://') || server.startsWith('https://')) &&
            kPairCodeRegExp.hasMatch(pairCode) &&
            shareToken.isNotEmpty) {
          return ScanResult.share(
              server: server, pairCode: pairCode, shareToken: shareToken);
        }
      }
      return null;
    }
    // 纯 8 位激活码（旧格式，使用默认服务器）
    final code = raw.trim().toUpperCase();
    return kActCodeRegExp.hasMatch(code) ? ScanResult.act(code: code) : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('扫描激活码'),
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
                    '将激活码二维码放入框内即可自动识别',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '二维码由电脑端软件在「用户管理 → 生成激活码」中显示',
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

/// 扫码结果（v5.18+ 双格式）：kind='act' 管理员激活码；kind='share' 共享码
class ScanResult {
  final String kind; // 'act' | 'share'
  final String? server; // 二维码内嵌服务器地址（旧格式为空）
  final String? code; // act：8 位激活码
  final String? pairCode; // share：10 位配对码
  final String? shareToken; // share：共享码

  const ScanResult.act({this.server, required this.code})
      : kind = 'act',
        pairCode = null,
        shareToken = null;

  const ScanResult.share(
      {this.server, required this.pairCode, required this.shareToken})
      : kind = 'share',
        code = null;
}

/// 配对码格式：10 位大写字母/数字（服务器生成，电脑端共享二维码内嵌）
final RegExp kPairCodeRegExp = RegExp(r'^[A-Z0-9]{10}$');
