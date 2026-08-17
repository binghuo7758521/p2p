import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_log.dart';
import 'silent_updater.dart';
import 'update_check.dart';
import 'version.dart';

/// 全局升级服务（v6.12+）：程序启动即检测，不依赖任何页面
///
/// 原逻辑在 HomePage.initState（要进主页面才检测）；改为应用级单例后，
/// 无论在连接页/授权页/主页面都能检测并弹窗，同时保留每 6 小时定时检查
/// （常开主机不重启也能收到新版提示）。
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 全局导航键（main.dart 的 MaterialApp 注入），弹窗不依赖页面 context
  /// v6.16 修复：此前声明为可空且从未初始化（永远为 null），导致 MaterialApp
  /// 使用内部默认 Navigator，本服务 _context 恒为 null，升级弹窗被静默吞掉
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Timer? _timer; // 每 6 小时定时检查（常开不重启也能收到新版提示）
  bool _dialogOpen = false; // 升级弹窗防重入（弹窗/升级期间不再触发）
  bool _upgrading = false; // 升级编排进行中
  DateTime? _nextRemindAt; // 用户点“稍后提醒”后的免打扰截止时间

  /// 启动升级服务：立即检查一次 + 每 6 小时定时检查
  /// （main() 中 runApp 后调用，异步不阻塞界面启动）
  void start() {
    _checkUpdate();
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => _checkUpdate());
  }

  BuildContext? get _context => navigatorKey.currentContext;

  /// 检查升级：服务器有新版本时弹窗提示（启动时 + 每 6 小时定时）
  Future<void> _checkUpdate() async {
    if (_dialogOpen || _upgrading) return; // 弹窗/升级中，跳过本次
    if (_nextRemindAt != null && DateTime.now().isBefore(_nextRemindAt!)) {
      return; // 用户点了“稍后提醒”，期限内不再打扰
    }
    final info = await checkDesktopUpdate();
    if (info == null || !info.needUpdate) return;
    final ctx = _context;
    if (ctx == null || !ctx.mounted) {
      // 导航上下文不可用时静默跳过会无从排障，记录日志便于定位
      AppLog.w('update', '导航上下文不可用，升级弹窗被跳过');
      return;
    }
    final hasMd5 = info.md5 != null && info.md5!.isNotEmpty;
    _dialogOpen = true;
    // v6.18：按钮 pop 带返回值，区分用户选择与“被页面导航顶掉”；
    // 启动早期连接页会 pushReplacement 到主页，栈顶弹窗会被顶掉（一闪而过），
    // 返回值 null 时延迟自愈重弹，确保用户能看到升级提示
    final action = await showDialog<String>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: Text('发现新版本 v${info.latest}'),
        content: Text(
          '当前版本 v$appVersion\n\n${info.notes}\n\n'
          '升级将自动下载、校验并重启，全程无需手动操作',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('later'),
            child: const Text('稍后提醒'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop('download'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('立即升级'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (!ctx.mounted) return;
    if (action == 'later') {
      // 24 小时内不再弹窗提醒（定时检查仍触发但被期限拦截）
      _nextRemindAt = DateTime.now().add(const Duration(hours: 24));
      return;
    }
    if (action == 'download') {
      if (info.url == null) return;
      if (hasMd5) {
        await _runSilentUpgrade(info);
      } else {
        // 服务器未提供校验值：回退手动浏览器下载
        openDownloadUrl(info.url!);
        _showUpdateError('服务器未提供升级包校验信息，已为你打开下载页面，'
            '请手动下载并解压覆盖程序目录');
      }
      return;
    }
    // null：弹窗被页面导航顶掉/系统关闭——延迟后自愈重弹，
    // 避免用户在启动早期的导航竞争里永远看不到升级提示
    AppLog.w('update', '升级弹窗被关闭/顶掉，延迟后重新弹出');
    await Future.delayed(const Duration(milliseconds: 800));
    if (_dialogOpen || _upgrading) return;
    _checkUpdate();
  }

  /// 静默升级：进度对话框 + 下载/校验/解压/重启编排
  Future<void> _runSilentUpgrade(UpdateInfo info) async {
    if (_upgrading) return; // 防重入（定时检查再次触发时）
    _upgrading = true;
    final ctx = _context;
    if (ctx == null) {
      _upgrading = false;
      return;
    }
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('正在准备升级…');

    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: const Text('正在升级'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, p, _) => LinearProgressIndicator(value: p),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, _) => Text(s, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );

    final ok = await runSilentUpgrade(
      downloadUrl: info.url!,
      expectedMd5: info.md5,
      onPhase: (phase, p, message) {
        progress.value = p;
        status.value = message;
      },
    );

    final ctx2 = _context;
    if (ctx2 == null || !ctx2.mounted) return;
    Navigator.of(ctx2).pop(); // 关闭进度对话框
    if (ok) {
      // 升级已编排：立即退出主程序，由 update.bat 完成替换与重启
      AppLog.i('update', '静默升级成功，主程序退出');
      exit(0);
    }
    _upgrading = false; // 升级失败：复位标志，允许后续再次升级
    if (info.url != null) openDownloadUrl(info.url!);
    _showUpdateError('自动升级失败，已为你打开下载页面，'
        '请手动下载并解压覆盖程序目录');
  }

  /// 升级失败提示
  void _showUpdateError(String message) {
    final ctx = _context;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline, color: Colors.red),
        title: const Text('升级失败'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
