import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'usb_drives.dart';

/// U盘ID查看工具：插入U盘后运行，显示每个U盘的卷序列号（ID），
/// 管理员把 ID 添加到服务器授权白名单后，该U盘才能解锁电脑端。
void main() {
  runApp(const UsbIdToolApp());
}

class UsbIdToolApp extends StatelessWidget {
  const UsbIdToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'U盘ID查看工具',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF38BDF8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<UsbDriveInfo> _drives = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    // 枚举放在 isolate 外简单执行即可（GetVolumeInformation 每盘一次查询）
    final drives = await Future(() => listUsbDrives());
    if (!mounted) return;
    setState(() {
      _drives = drives;
      _loading = false;
    });
  }

  Future<void> _copy(UsbDriveInfo d) async {
    await Clipboard.setData(ClipboardData(text: d.serial));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已复制 ${d.serial}'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('U盘ID查看工具'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              margin: EdgeInsets.zero,
              color: const Color(0xFFEFF6FF),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '插入U盘后点击右上角刷新，把下面的 ID 提供给管理员添加到授权白名单。\n'
                  'ID 格式：XXXX-XXXX（每块U盘唯一，格式化U盘不会改变）',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: const Color(0xFF1E40AF)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '检测到 ${_drives.length} 个U盘',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _drives.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.usb_off,
                                  size: 56, color: Colors.grey),
                              SizedBox(height: 8),
                              Text('未检测到U盘，请插入U盘后刷新',
                                  style: TextStyle(color: Colors.grey)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _drives.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final d = _drives[i];
                            return Card(
                              margin: EdgeInsets.zero,
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    const Icon(Icons.usb,
                                        size: 32,
                                        color: Color(0xFF38BDF8)),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${d.letter}: '
                                            '${d.volumeLabel.isEmpty ? '(无卷标)' : d.volumeLabel}',
                                            style: theme.textTheme.bodyMedium,
                                          ),
                                          const SizedBox(height: 4),
                                          SelectableText(
                                            d.serial,
                                            style: theme.textTheme.titleLarge
                                                ?.copyWith(
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 2,
                                              color: const Color(0xFFF59E0B),
                                              fontFeatures: const [
                                                FontFeature
                                                    .tabularFigures()
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: () => _copy(d),
                                      icon: const Icon(Icons.copy, size: 16),
                                      label: const Text('复制'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
