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
/// 无论在连接页/授权页/主页面都能检测并弹窗，同时保留定时检查
/// （常开主机不重启也能收到新版提示）。
/// v6.23+：服务器 upgrade:notify 推送触发 checkNow() 秒级检查；
/// 检测到重要升级（urgent）切换每 5 分钟高频检查，直到升级完成。
/// v6.24+：服务器下线线（版本不再支持）返回 force，弹强制升级窗并高频检查
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  /// 全局导航键（main.dart 的 MaterialApp 注入），弹窗不依赖页面 context
  /// v6.16 修复：此前声明为可空且从未初始化（永远为 null），导致 MaterialApp
  /// 使用内部默认 Navigator，本服务 _context 恒为 null，升级弹窗被静默吞掉
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Timer? _timer; // 定时检查（普通升级 6h / 重要升级 5 分钟）
  bool _dialogOpen = false; // 升级弹窗防重入（弹窗/升级期间不再触发）
  bool _upgrading = false; // 升级编排进行中
  bool _urgentMode = false; // 重要升级模式：每 5 分钟高频检查直到升级完成
  DateTime? _nextRemindAt; // 用户点“稍后提醒”后的免打扰截止时间

  /// 启动升级服务：立即检查一次 + 每 6 小时定时检查
  /// （main() 中 runApp 后调用，异步不阻塞界面启动）
  void start() {
    _checkUpdate();
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => _checkUpdate());
  }

  /// 立即检查升级（服务器 upgrade:notify 推送时由 HostController 调用）
  Future<void> checkNow() => _checkUpdate();

  /// 管理员远程确认升级（v6.26+）：跳过确认弹窗直接静默升级。
  /// 由 HostController 在收到服务器 upgrade:confirmed 时调用；
  /// onResult 回调结果（成功时进程即将退出重启，不会回调）
  Future<void> upgradeNow({void Function(bool ok, String error)? onResult}) async {
    if (_upgrading) return; // 正在升级中，忽略重复确认
    final info = await checkDesktopUpdate();
    if (info == null) {
      onResult?.call(false, '无法连接服务器，请稍后再试');
      return;
    }
    if (!info.needUpdate || info.url == null) {
      onResult?.call(false, '当前已是最新版本，无需升级');
      return;
    }
    if (info.md5 == null || info.md5!.isEmpty) {
      openDownloadUrl(info.url!);
      onResult?.call(false, '服务器未提供升级包校验信息，已打开下载页面');
      return;
    }
    await _runSilentUpgrade(info, onResult: onResult);
  }

  /// 重要升级：切换为每 5 分钟高频检查（服务器仍标记 urgent 时保持），
  /// 直到升级完成（程序重启）或服务器撤销紧急标记
  void _switchToUrgentTimer() {
    if (_urgentMode) return;
    _urgentMode = true;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _checkUpdate());
    AppLog.i('update', '重要升级模式：切换为每 5 分钟高频检查');
  }

  /// 服务器不再标记重要升级：恢复每 6 小时常规检查
  void _restoreNormalTimer() {
    if (!_urgentMode) return;
    _urgentMode = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _checkUpdate());
    AppLog.i('update', '服务器已无重要升级，恢复每 6 小时常规检查');
  }

  BuildContext? get _context => navigatorKey.currentContext;

  /// 检查升级：服务器有新版本时弹窗提示（启动时 + 定时 + 服务器推送）
  Future<void> _checkUpdate() async {
    if (_dialogOpen || _upgrading) return; // 弹窗/升级中，跳过本次
    if (_nextRemindAt != null && DateTime.now().isBefore(_nextRemindAt!)) {
      return; // 用户点了“稍后提醒”，期限内不再打扰
    }
    final info = await checkDesktopUpdate();
    if (info == null || !info.needUpdate) {
      // 重要升级被服务器撤销（info 非空）：恢复常规频率；
      // 网络异常（info==null）保持当前频率，避免误恢复后错过提示
      if (_urgentMode && info != null) _restoreNormalTimer();
      return;
    }
    // v6.23+：重要升级立即切换高频检查（普通升级保持 6 小时）
    // v6.24+：版本不再支持（force）同样高频检查，且免打扰期仅 5 分钟
    if (info.force || info.urgent) _switchToUrgentTimer();
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
    // v6.23+：重要升级（urgent）标题/文案区分，“稍后提醒”缩为 1 小时
    // v6.24+：不再支持（force）标题/文案再区分，“稍后提醒”缩为 5 分钟
    final remindAfter = info.force
        ? const Duration(minutes: 5)
        : (info.urgent ? const Duration(hours: 1) : const Duration(hours: 24));
    final action = await showDialog<String>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        icon: Icon(
            info.force ? Icons.block : Icons.system_update_alt,
            color: info.force ? Colors.red : const Color(0xFF38BDF8)),
        title: Text(
            info.force
                ? '此版本已不再支持：请立即升级到 v${info.latest}'
                : (info.urgent
                    ? '重要升级：请尽快更新到 v${info.latest}'
                    : '发现新版本 v${info.latest}')),
        content: Text(
          '当前版本 v$appVersion\n\n${info.notes}\n\n'
          '${info.force
              ? '服务器已停止支持当前版本，不升级将无法正常使用。\n'
              : (info.urgent ? '本次为重要升级，建议尽快更新。\n' : '')}'
          '升级将自动下载、校验并重启，全程无需手动操作',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('later'),
            child: Text(info.force ? '稍后(5分钟)' : '稍后提醒'),
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
      // 不再支持 5 分钟 / 重要升级 1 小时 / 普通升级 24 小时免打扰
      // （定时检查仍触发但被期限拦截）
      _nextRemindAt = DateTime.now().add(remindAfter);
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

  /// 静默升级：进度对话框 + 下载/校验/解压/重启编排。
  /// v6.26+：onResult 可选——管理员远程确认升级时由 HostController
  /// 传入并上报服务器；本地确认升级时不传（沿用原错误提示）
  Future<void> _runSilentUpgrade(UpdateInfo info,
      {void Function(bool ok, String error)? onResult}) async {
    if (_upgrading) return; // 防重入（定时检查再次触发时）
    _upgrading = true;
    final ctx = _context;
    if (ctx == null) {
      _upgrading = false;
      onResult?.call(false, '界面未就绪，无法执行升级');
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
      // v6.27+：MD5 校验失败时重新获取最新升级信息重试（发布窗口期自愈）
      refreshInfo: () => checkDesktopUpdate(),
    );

    final ctx2 = _context;
    if (ctx2 == null || !ctx2.mounted) {
      _upgrading = false;
      onResult?.call(false, '升级执行异常，请到电脑前手动处理');
      return;
    }
    Navigator.of(ctx2).pop(); // 关闭进度对话框
    if (ok) {
      // 升级已编排：立即退出主程序，由 update.bat 完成替换与重启
      AppLog.i('update', '静默升级成功，主程序退出');
      exit(0);
    }
    _upgrading = false; // 升级失败：复位标志，允许后续再次升级
    onResult?.call(false, '自动升级失败，请到电脑前手动处理');
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
