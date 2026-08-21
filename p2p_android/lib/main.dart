import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'activate_page.dart';
import 'app_controller.dart';
import 'app_log.dart';
import 'auth_service.dart';
import 'home_page.dart';
import 'update_check.dart';
import 'version.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppLog.init();
  // v5.43+：后台保活前台服务初始化。连接电脑后启动服务，
  // App 退后台/息屏时进程与定时器不被冻结，自动重连可持续执行
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'p2p_keep_alive',
      channelName: 'P2P 连接保活',
      channelDescription: '保持与电脑端的连接，电脑端上线时自动重连',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  AppLog.i('app', '手机端启动 v$appVersion');
  runApp(const P2pApp());
}

class P2pApp extends StatelessWidget {
  const P2pApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '无限大盘 v$appVersion',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF38BDF8),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      home: const _AuthGate(),
    );
  }
}

/// 启动门禁：已激活直接进主页，未激活先进激活页
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _loading = true;
  bool _loggedIn = false;
  /// 强制升级弹窗去重：连接被拒可能多次触发 onVersionRequired
  bool _forceShown = false;
  /// 门禁层持有 controller：升级弹窗需感知配对状态，
  /// 避免弹窗弹出后被配对成功的页面跳转（pushReplacement HomePage）盖住
  final AppController _controller = AppController();

  @override
  void initState() {
    super.initState();
    // v5.6+ 强制升级：服务器拒绝旧版连接（APP_VERSION_REQUIRED）时，
    // 无论当前在哪个页面都弹不可跳过的强制升级窗
    _controller.onVersionRequired = () {
      if (!mounted || _forceShown) return;
      _forceShown = true;
      unawaited(handleVersionRequired(context)
          .whenComplete(() => _forceShown = false));
    };
    _init();
  }

  Future<void> _init() async {
    final ok = await AuthService.instance.load();
    // v5.19+：共享访客身份（type='guest'，纯本地标记，无设备令牌）
    // 启动即恢复访客模式：直接进主页共享模式，不进激活页
    if (AuthService.instance.type == 'guest') {
      _controller.isShareGuest = true;
    }
    AppLog.i('app', '启动门禁: ${ok ? '已激活→主页' : AuthService.instance.type == 'guest' ? '共享访客→主页' : '未激活→激活页'}');
    if (!mounted) return;
    setState(() {
      // 访客身份（无令牌，load 返回 false）同样放行进主页
      _loggedIn = ok || AuthService.instance.type == 'guest';
      _loading = false;
    });
    _checkUpdate();
  }

  /// 启动时检查升级：服务器有新版本时弹窗提示（每次启动检查一次）
  Future<void> _checkUpdate() async {
    final info = await checkAndroidUpdate();
    if (!mounted || info == null) return;
    // v5.6+ 强制升级：服务器标记 force（旧版已停止服务）时立即弹不可跳过升级窗
    if (info.force) {
      await showForcedUpdateDialog(context, info);
      return;
    }
    if (!info.needUpdate) return;
    if (_loggedIn) {
      // 已激活：主页会自动直连（HomePage.initState 读取配对历史），
      // 若弹窗与页面切换竞争会出现“一闪而过”难以点击。
      // 等待连接结果稳定后再弹：
      // - paired/peerConnected/lost：连接已定（主页已进或即将进入）
      // - error：连接失败停在连接页，无跳转
      // - connecting/idle：连接未定，继续等待（最多 30 秒，超时放弃本次提示）
      ConnectState? stable;
      for (var i = 0; i < 100; i++) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (!mounted) return;
        final s = _controller.state;
        if (s == ConnectState.paired ||
            s == ConnectState.peerConnected ||
            s == ConnectState.lost ||
            s == ConnectState.error ||
            // 无配对信息的用户停在主页未连接视图，也是稳定状态
            s == ConnectState.idle) {
          stable = s;
          break;
        }
      }
      if (stable == null) return; // 长时间未稳定：放弃本次提示，避免与导航竞争
      // 页面切换动画（约 300ms）与主页首帧渲染完成后弹窗，确保稳定置顶
      await Future.delayed(const Duration(milliseconds: 1000));
    } else {
      // 未激活：激活页不会自动跳转，稍等片刻直接弹
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    await _showUpdateDialog(info);
  }

  /// 弹出升级提示：弹窗被其他导航盖住时自动重新弹出，确保用户能看到并点击。
  /// 仅当用户明确选择“立即下载”或“稍后”才结束。
  Future<void> _showUpdateDialog(UpdateInfo info) async {
    while (mounted) {
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false, // 外部点击不关闭，避免误触
        builder: (ctx) => _UpdateDialog(info: info),
      );
      if (!mounted) return;
      if (action == 'download') {
        if (info.url != null) {
          await _downloadAndInstall(info.url!, expectedMd5: info.md5);
        }
        return;
      }
      if (action == 'later') return;
      // action == null：弹窗被导航盖住后自愈关闭（或系统返回键）：
      // 重新弹出，确保用户能看到升级提示
      AppLog.i('app', '升级弹窗被盖/关闭，重新弹出');
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  /// App 内下载升级包（v4.9+：升级包在对象存储，浏览器直链受限）：
  /// 显示下载进度，完成后拉起系统安装器
  /// v5.22：携带服务器 MD5，下载后校验防止 OSS 漏同步装成旧版
  Future<void> _downloadAndInstall(String url, {String? expectedMd5}) async {
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('准备下载…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('下载升级包'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (ctx, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (p == null)
                const CircularProgressIndicator()
              else
                LinearProgressIndicator(value: p),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (ctx, s, _) => Text(s),
              ),
            ],
          ),
        ),
      ),
    );
    final result = await downloadAndInstallApk(
      url,
      expectedMd5: expectedMd5,
      context: context,
      onProgress: (received, total) {
        progress.value = total > 0 ? received / total : null;
        status.value = total > 0
            ? '已下载 ${(received / 1048576).toStringAsFixed(1)} / '
                '${(total / 1048576).toStringAsFixed(1)} MB'
            : '已下载 $received 字节';
      },
    );
    if (!mounted) return;
    Navigator.of(context).pop(); // 关闭进度对话框
    // 按安装结果提示（v5.2：未授权/失败不再静默）
    final msg = switch (result) {
      InstallResult.installed => '升级包已下载，请在系统安装界面确认安装',
      InstallResult.needPermission => '请到系统设置开启安装权限后重试升级',
      InstallResult.cancelled => '已取消升级，可稍后在升级提示中重试',
      InstallResult.failed => '下载或安装失败，请重新尝试升级',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_loggedIn) {
      // 已激活直接进入主页面：不强制先连接电脑。
      // 无电脑端权限的客户端也可进入主页浏览分享的共享文件夹；
      // 有历史配对信息的用户在主页自动直连（HomePage.initState）
      return HomePage(controller: _controller);
    }
    return ActivatePage(controller: _controller);
  }
}

/// 升级提示弹窗：显示期间持续检查自身是否仍位于路由栈顶，
/// 若被后续导航盖住（无法点击）则自动关闭，由外层 _showUpdateDialog 重新弹出
class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;

  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  Timer? _checker;

  @override
  void initState() {
    super.initState();
    // 每 600ms 检查一次是否仍在栈顶（isCurrent）；被盖则 pop 触发外层重弹
    _checker = Timer.periodic(const Duration(milliseconds: 600), (_) {
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        _checker?.cancel();
        if (mounted) Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _checker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
      title: Text('发现新版本 v${info.latest}'),
      content: Text(
        '当前版本 v$appVersion\n\n${info.notes}\n\n'
        '下载后将通过系统安装器安装，请确认允许安装未知来源应用',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('later'),
          child: const Text('稍后'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop('download'),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('立即下载'),
        ),
      ],
    );
  }
}
