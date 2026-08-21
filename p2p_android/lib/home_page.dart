import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'about_page.dart';
import 'app_controller.dart';
import 'app_log.dart';
import 'auth_service.dart';
import 'connect_page.dart';
import 'download_banner.dart';
import 'models.dart';
import 'protocol.dart';
import 'scan_page.dart';
import 'share_browse_page.dart';
import 'update_check.dart';
import 'share_center_page.dart';
import 'users_page.dart';
import 'version.dart';
import 'video_play_service.dart';
import 'video_player_page.dart';

/// 主界面：浏览 / 上传 / 传输
class HomePage extends StatefulWidget {
  final AppController controller;

  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  bool _claimDialogShowing = false; // 管理员更换确认弹窗防重复
  bool _powerNoticeShowing = false; // 电源控制提示条防重复

  @override
  void initState() {
    super.initState();
    _maybeAutoConnect();
  }

  /// 冷启动（主页为登录后第一页）：有历史配对信息则自动直连；
  /// 无配对信息（没有自己的电脑）停留未连接视图，可手动连接或浏览共享；
  /// v5.11+：非管理员启动时不自动连接任何电脑端，
  /// 避免扫码加入多个共享后后台逐个连电脑，改为点击共享/历史条目时才连接
  Future<void> _maybeAutoConnect() async {
    final c = widget.controller;
    if (c.state != ConnectState.idle) return; // 已在连接/已连接/重连中
    if (AuthService.instance.type != 'admin') {
      AppLog.i('connect', '非管理员，跳过启动自动直连');
      return;
    }
    final info = await c.loadPairInfo();
    if (!mounted || info == null) return;
    c.autoMode = true;
    AppLog.i('connect', '主页自动直连: server=${info.server}');
    await c.connect(info.server, info.code.toUpperCase());
  }

  /// 扫描共享二维码：已连同一电脑端直接附加共享，否则跳连接页自动连接
  Future<void> _scanShareCode() async {
    final result = await Navigator.of(context).push<ScanPairResult>(
      MaterialPageRoute(builder: (_) => const ScanPage()),
    );
    if (result == null || !mounted) return;
    final ctrl = widget.controller;
    AppLog.i('share',
        '扫码: server=${result.server} code=${result.code} token=${result.shareToken}');
    // v5.23+：管理员激活码（p2p-act:）——已激活手机成为另一台电脑管理员
    if (result.isAct) {
      await _activateNewHost(ctrl, result);
      return;
    }
    if (result.shareToken != null &&
        ctrl.state == ConnectState.peerConnected &&
        result.server == ctrl.lastServerUrl &&
        result.code.toUpperCase() == ctrl.lastPairCode?.toUpperCase()) {
      // 已连接同一电脑端：直接附加共享目录
      ctrl.attachShare(result.shareToken!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('正在附加共享目录…'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    // 未连接/其他电脑端：进入连接页自动连接（携带共享码）
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ConnectPage(
        controller: ctrl,
        autoConnect: false,
        initialServer: result.server,
        initialCode: result.code,
        pendingShareToken: result.shareToken,
      ),
    ));
  }

  /// v5.23+：已激活手机扫码电脑端管理员码，成为另一台电脑管理员。
  /// 激活后旧电脑的共享列表失效（设备令牌被替换），配对记录保留可直连；
  /// 确认后覆盖本地激活态并自动连接新电脑
  Future<void> _activateNewHost(AppController ctrl, ScanPairResult result) async {
    final code = result.code.toUpperCase();
    AppLog.i('auth', '扫码管理员码: server=${result.server} code=$code');
    // 已连接同一台电脑：无需重新激活
    if (ctrl.state == ConnectState.peerConnected &&
        result.server == ctrl.lastServerUrl &&
        code == ctrl.lastPairCode?.toUpperCase()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已连接该电脑，无需重复激活')));
      return;
    }
    // v5.17+ 激活前即时校验：已使用的码提示失效，不弹确认
    final valid = await AuthService.instance
        .checkActCodeValid(result.server, code);
    if (!mounted) return;
    if (!valid) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('激活码已失效（已被使用），请重新获取')));
      return;
    }
    // 确认弹窗：明确告知原电脑共享列表将失效、直连保留
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('成为这台电脑的管理员？'),
        content: const Text(
            '激活后将接管该电脑的管理权限，并自动连接。\n\n'
            '注意：原电脑的共享列表将失效（管理员身份被替换），'
            '但电脑配对记录会保留，可随时切换连接。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确认激活')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final act = await AuthService.instance
          .activate(result.server, code, ctrl.deviceId);
      await AuthService.instance.save(
        deviceToken: act.deviceToken,
        pairCode: act.pairCode,
        type: act.type,
        activationCode: code,
      );
      AppLog.i('auth', '扫码激活成功，连接新电脑: ${act.pairCode}');
      // 激活即自动直连新电脑（失败时主页显示重连视图）
      ctrl.autoMode = true;
      await ctrl.connect(result.server, act.pairCode);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('激活成功，已连接新电脑'),
          duration: Duration(seconds: 2)));
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      AppLog.e('auth', '扫码激活失败', e);
      // v5.6+ 强制升级：旧版被服务器拒绝激活，弹不可跳过的升级窗
      if (msg == 'APP_VERSION_REQUIRED') {
        unawaited(handleVersionRequired(context));
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('激活失败: $msg')));
    }
  }

  // ── 主页内切换连接目标（电脑/共享文件夹） ────────────────

  /// 历史条目标题：电脑用码尾 4 位区分；共享用共享文件夹名
  String _historyTitle(PairInfo h) {
    if (h.name != null && h.name!.isNotEmpty) return h.name!;
    return h.isShare ? '共享文件夹' : '电脑 ${_codeSuffix(h.code)}';
  }

  /// 配对码尾 4 位（多台电脑区分标识）
  static String _codeSuffix(String code) =>
      code.length >= 4 ? code.substring(code.length - 4) : code;

  /// 最近连接时间的相对描述
  static String _fmtTime(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 当前连接目标是否为该历史条目（已连接则无需切换）
  bool _isCurrentTarget(PairInfo info, AppController c) {
    final srv = c.lastServerUrl?.replaceAll(RegExp(r'/$'), '') ?? '';
    final code = c.lastPairCode?.trim().toUpperCase() ?? '';
    if (srv.isEmpty || code.isEmpty) return false;
    if (info.server.replaceAll(RegExp(r'/$'), '') != srv) return false;
    if (info.code.trim().toUpperCase() != code) return false;
    // 共享记录仅当当前为共享访客时视为同一目标
    return info.isShare ? c.isShareGuest : !c.isShareGuest;
  }

  /// 弹出历史设备列表（主页内切换连接目标）
  Future<void> _showSwitchSheet() async {
    final c = widget.controller;
    final list = await c.loadPairInfos();
    if (!mounted) return;
    if (list.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('暂无历史记录，请先使用激活码激活电脑')));
      return;
    }
    final history = List<PairInfo>.from(list);
    final connected = c.state == ConnectState.peerConnected;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final theme = Theme.of(ctx);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Row(
                    children: [
                      Text('切换连接目标',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('点击条目即可切换',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Colors.grey)),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: history.length,
                    itemBuilder: (_, i) {
                      final h = history[i];
                      final isCurrent = connected && _isCurrentTarget(h, c);
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 0,
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                              h.isShare
                                  ? Icons.folder_shared
                                  : Icons.desktop_windows,
                              color: h.isShare
                                  ? const Color(0xFF38BDF8)
                                  : theme.colorScheme.primary),
                          title: Text(
                              isCurrent &&
                                      c.hostName != null &&
                                      c.hostName != '电脑'
                                  ? c.hostName!
                                  : _historyTitle(h)),
                          subtitle: Text(
                            (_fmtTime(h.lastAt).isEmpty
                                ? ''
                                : '最近连接 · ${_fmtTime(h.lastAt)}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isCurrent)
                                const Icon(Icons.check_circle,
                                    color: Colors.green, size: 20),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20),
                                tooltip: '删除记录',
                                onPressed: () => _removeHistoryItem(
                                    ctx, h, history, setSheetState, c),
                              ),
                            ],
                          ),
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            if (isCurrent) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('已连接该设备')));
                              return;
                            }
                            await _switchTo(h);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 切换连接目标：断开当前连接后连接所选设备（失败立即提示）
  Future<void> _switchTo(PairInfo info) async {
    final c = widget.controller;
    AppLog.i('connect', '主页切换连接: ${info.isShare ? '共享' : '电脑'} code=${info.code}');
    c.autoMode = false; // 手动切换：失败立即提示，不自动重试
    await c.disconnect();
    await c.connect(info.server, info.code.toUpperCase(),
        shareToken: info.shareToken);
    // 等待连接结果，失败时提示（主页无连接页的配对等待循环）
    for (var i = 0; i < 30 && mounted; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (c.state == ConnectState.peerConnected) break;
      if (c.state == ConnectState.error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('切换失败：${c.errorMessage ?? '连接失败'}')));
        }
        break;
      }
    }
  }

  /// 删除历史记录（底部弹窗内调用，确认后移除）
  Future<void> _removeHistoryItem(
      BuildContext ctx,
      PairInfo info,
      List<PairInfo> history,
      StateSetter setSheetState,
      AppController c) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('删除记录'),
        content:
            Text('删除后将不再显示「${_historyTitle(info)}」\n确认删除？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !ctx.mounted) return;
    await c.removePairInfo(info.server, info.code,
        shareToken: info.shareToken);
    setSheetState(() => history
        .removeWhere((h) => h.server == info.server && h.code == info.code));
  }

  /// 显示操作结果提示（共享附加/删除等，显示后自动清除）
  void _showActionMessage(AppController controller) {
    final msg = controller.actionMessage;
    if (msg == null) return;
    controller.clearActionMessage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
      ));
    });
  }

  /// 远程电源控制确认（v5.9）：仅管理员入口可见；确认后发送指令
  Future<void> _confirmRemotePower(String value) async {
    final shutdown = value == 'power_shutdown';
    final label = shutdown ? '关机' : '重启';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('远程$label'),
        content: Text('确认要远程$label电「${widget.controller.hostName ?? '电脑'}」吗？\n\n'
            '未保存的工作可能会丢失！执行后 15 秒内可在手机端取消。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('确认$label'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      widget.controller.remotePower(shutdown ? 'shutdown' : 'reboot');
    }
  }

  /// 远程自动登录设置（v5.13）：仅管理员入口可见；
  /// 电脑端须以管理员身份运行方可远程写入（回执会明确提示）
  Future<void> _openAutoLoginDialog() async {
    final c = widget.controller;
    if (!c.isAdmin) return;
    // 先查询当前状态
    final status = await c.remoteAutoLogin('status');
    if (!mounted) return;
    if (status == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('无响应：电脑端版本过旧或未连接，请升级电脑端后重试'),
      ));
      return;
    }
    if (status['ok'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status['error']?.toString() ?? '查询自动登录状态失败'),
      ));
      return;
    }
    final enabled = status['enabled'] == true;
    final elevated = status['elevated'] == true;
    final pwdCtrl = TextEditingController();
    final act = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('自动登录设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('电脑端：${c.hostName ?? '未知'}\n'
                  '当前状态：${enabled ? '已开启' : '已关闭'}'),
              if (!elevated)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '⚠ 电脑端未以管理员身份运行，无法远程设置：'
                    '请在电脑上右键程序图标选择“以管理员身份运行”后重试',
                    style: TextStyle(color: Colors.orange, fontSize: 12),
                  ),
                ),
              if (!enabled) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: pwdCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Windows 登录密码',
                    border: OutlineInputBorder(),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '⚠ 密码将以明文存储于电脑注册表（HKLM\\...\\Winlogon），'
                    '仅建议在可信环境使用；若系统盘启用 BitLocker 加密，'
                    '重启时仍需先解锁磁盘，本功能无效',
                    style: TextStyle(color: Colors.orange, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('close'),
            child: const Text('取消'),
          ),
          if (enabled)
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('disable'),
              child: const Text('关闭自动登录'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('enable'),
              child: const Text('开启'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (act == null || act == 'close') return;
    if (act == 'enable' && pwdCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请输入 Windows 登录密码')));
      return;
    }
    final r = await c.remoteAutoLogin(
      act == 'enable' ? 'enable' : 'disable',
      password: act == 'enable' ? pwdCtrl.text : null,
    );
    if (!mounted) return;
    final msg = r == null
        ? '无响应：电脑端版本过旧或未连接，请升级电脑端后重试'
        : (r['ok'] == true
            ? (act == 'enable'
                ? '已开启重启后自动登录，下次重启生效'
                : '已关闭重启后自动登录，下次重启需输入密码')
            : (r['error']?.toString() ?? '设置失败'));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 远程电源控制回执提示（v5.9）：执行后倒计时内可点“取消”中止
  void _showPowerNotice(AppController c) {
    final n = c.powerNotice;
    if (n == null || _powerNoticeShowing || !mounted) return;
    _powerNoticeShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(
            content: Text(n.text),
            duration: Duration(seconds: n.delaySeconds),
            // 执行类操作在倒计时内可取消（cancel 回执不显示按钮）
            action: n.delaySeconds > 3
                ? SnackBarAction(
                    label: '取消',
                    onPressed: () => c.remotePower('cancel'),
                  )
                : null,
          ))
          .closed.then((_) {
        _powerNoticeShowing = false;
        c.clearPowerNotice();
      });
    });
  }

  /// 电脑端已有其他管理员：弹出更换确认（确认后申请成为管理员）
  void _maybeShowAdminClaimDialog(AppController c) {
    final req = c.adminClaimRequest;
    if (req == null || _claimDialogShowing || !mounted) return;
    _claimDialogShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('更换管理员'),
          content: Text('该电脑端已有管理员（${req.adminName}）\n\n'
              '是否将管理员更换为您？原管理员将自动降级，失去管理权限。'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                c.rejectAdminClaim();
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                c.confirmAdminClaim();
              },
              child: const Text('更换为管理员'),
            ),
          ],
        ),
      ).then((_) => _claimDialogShowing = false);
    });
  }

  /// 连接密码校验失败：弹出密码输入框（v5.4+），
  /// 确认后重新连接并自动验证；取消则断开保持未连接
  void _maybeShowPasswordDialog(AppController c) {
    final err = c.authError;
    if (err == null || _claimDialogShowing || !mounted) return;
    _claimDialogShowing = true;
    final ctrl = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('连接密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(err, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                obscureText: true,
                maxLength: 16,
                decoration: const InputDecoration(
                  labelText: '连接密码',
                  hintText: '由电脑端管理员设置/重置',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                c.consumeAuthError();
              },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final pwd = ctrl.text;
                Navigator.of(ctx).pop();
                if (pwd.isEmpty) {
                  c.consumeAuthError();
                  return;
                }
                c.submitPassword(pwd);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ).then((_) {
        ctrl.dispose();
        _claimDialogShowing = false;
      });
    });
  }

  /// 一键上传运行日志到服务器（开发者远程排查用）
  Future<void> _uploadLog() async {
    final server = widget.controller.lastServerUrl;
    final messenger = ScaffoldMessenger.of(context);
    if (server == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('未连接服务器，无法上传日志')));
      return;
    }
    messenger.showSnackBar(const SnackBar(
        content: Text('正在上传日志…'), duration: Duration(seconds: 2)));
    try {
      final logText = await AppLog.readLog();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final uri = Uri.parse('$server/log-upload').replace(queryParameters: {
          'deviceId': widget.controller.deviceId,
          'version': appVersion,
        });
        final req = await client.postUrl(uri);
        req.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        req.write(logText);
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode == 200) {
          final logId = (jsonDecode(body) as Map)['logId'] ?? '';
          AppLog.i('upload', '日志上传成功: $logId');
          messenger.showSnackBar(SnackBar(
              content: Text('日志已上传（$logId），请告知开发者')));
        } else {
          AppLog.e('upload', '日志上传失败: HTTP ${resp.statusCode}');
          messenger.showSnackBar(
              const SnackBar(content: Text('日志上传失败，请稍后重试')));
        }
      } finally {
        client.close();
      }
    } catch (e) {
      AppLog.e('upload', '日志上传异常', e);
      messenger.showSnackBar(
          SnackBar(content: Text('日志上传失败: $e')));
    }
  }

  /// 下载完成：弹操作面板（打开 / 保存到手机 / 分享）
  void _showDownloadDone(AppController controller) {
    final done = controller.takeLastDownloadDone();
    if (done == null) return;
    AppLog.i('download', '弹出下载完成操作面板: ${done.name}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('下载完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(done.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '文件已保存在应用目录。点"保存到手机"可存到下载、相册等任意位置。',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final r = await OpenFilex.open(done.path);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(r.type == ResultType.done
                      ? '已打开: ${done.name}'
                      : '无法打开该文件: ${r.message}'),
                  duration: const Duration(seconds: 2),
                ));
              },
              child: const Text('打开'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  final saved = await FlutterFileDialog.saveFile(
                      params: SaveFileDialogParams(
                    sourceFilePath: done.path,
                    fileName: done.name,
                  ));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(saved != null
                        ? '已保存到: $saved'
                        : '已取消保存'),
                    duration: const Duration(seconds: 3),
                  ));
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('保存失败: $e'),
                    duration: const Duration(seconds: 3),
                  ));
                }
              },
              child: const Text('保存到手机'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await SharePlus.instance.share(ShareParams(
                  files: [XFile(done.path)],
                  text: '已从电脑下载: ${done.name}',
                ));
              },
              child: const Text('分享'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final connected =
                controller.state == ConnectState.peerConnected;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('无限大盘 v$appVersion',
                    style: const TextStyle(fontSize: 18)),
                // 电脑名称与连接方式同行显示：名称过长时省略号截断，
                // 不再溢出截断（v5.1 标题区优化）
                if (connected)
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '已连接: ${controller.hostName ?? '电脑'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.green),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _ConnBadge(controller: controller),
                    ],
                  )
                else
                  const Text('未连接',
                      style: TextStyle(
                          fontSize: 12, color: Colors.redAccent)),
              ],
            );
          },
        ),
        actions: [
          // “共享给我的”入口（v5.4+）：激活后常显，免配对码连接服务器共享；
          // v5.19+：共享访客（无激活令牌）同样显示
          if (AuthService.instance.activated || controller.isShareGuest)
            IconButton(
              tooltip: '共享给我的',
              icon: const Icon(Icons.inbox_outlined),
              onPressed: () {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        ShareCenterPage(controller: controller)));
              },
            ),
          IconButton(
            tooltip: '扫共享二维码',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanShareCode,
          ),
          IconButton(
            tooltip: '断开连接',
            icon: const Icon(Icons.link_off),
            onPressed: () async {
              // 断开后停留在主页（未连接引导视图），不再强制跳连接页
              await controller.disconnect();
            },
          ),
          // ⋮ 更多：低频操作收纳（菜单项在弹出时实时读取连接/管理员状态）
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              switch (value) {
                case 'switch':
                  _showSwitchSheet();
                case 'manage':
                  controller.refreshUserList();
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => UsersPage(controller: controller)));
                case 'power_shutdown':
                case 'power_reboot':
                  await _confirmRemotePower(value);
                case 'auto_login':
                  await _openAutoLoginDialog();
                case 'copy_log':
                  final logText = await AppLog.readLog();
                  if (!context.mounted) return;
                  await Clipboard.setData(ClipboardData(text: logText));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('运行日志已复制，请直接粘贴给开发者排查'),
                  ));
                case 'upload_log':
                  _uploadLog();
                  return;
                case 'about':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => AboutPage(controller: controller)));
                  return;
              }
            },
            itemBuilder: (context) {
              final connected =
                  controller.state == ConnectState.peerConnected;
              return [
                // v5.20+：切换连接目标仅管理员可见（本地管理员身份判定，
                // 断开连接后仍可切换）——该功能用于管理员在多台电脑间
                // 切换；访客/无权限用户走「共享给我的」，无需此入口
                if (AuthService.instance.type == 'admin')
                  const PopupMenuItem(
                    value: 'switch',
                    child: _MenuRow(
                        icon: Icons.swap_horiz, label: '切换连接目标'),
                  ),
                if (connected && controller.isAdmin)
                  const PopupMenuItem(
                    value: 'manage',
                    child: _MenuRow(
                        icon: Icons.folder_shared_outlined,
                        label: '共享文件夹管理'),
                  ),
                if (connected && controller.isAdmin) ...[
                  const PopupMenuItem(
                    value: 'power_shutdown',
                    child: _MenuRow(
                        icon: Icons.power_settings_new, label: '远程关机'),
                  ),
                  const PopupMenuItem(
                    value: 'power_reboot',
                    child: _MenuRow(
                        icon: Icons.restart_alt, label: '远程重启'),
                  ),
                  const PopupMenuItem(
                    value: 'auto_login',
                    child: _MenuRow(
                        icon: Icons.lock_open, label: '自动登录设置'),
                  ),
                ],
                const PopupMenuItem(
                  value: 'copy_log',
                  child: _MenuRow(
                      icon: Icons.article_outlined, label: '复制运行日志'),
                ),
                const PopupMenuItem(
                  value: 'upload_log',
                  child: _MenuRow(
                      icon: Icons.cloud_upload_outlined,
                      label: '上传日志给开发者'),
                ),
                const PopupMenuItem(
                  value: 'about',
                  child: _MenuRow(
                      icon: Icons.info_outline, label: '关于'),
                ),
              ];
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          _showActionMessage(controller);
          _showPowerNotice(controller);
          _showDownloadDone(controller);
          _maybeShowAdminClaimDialog(controller);
          _maybeShowPasswordDialog(controller);
          Widget body;
          if (controller.state == ConnectState.lost) {
            body = _LostView(controller: controller);
          } else if (controller.state != ConnectState.peerConnected) {
            // 未连接（idle/connecting/paired/error）：显示连接引导视图，
            // 不阻塞主页面使用（无电脑端权限的客户端也可浏览分享的共享文件夹）
            body = _NotConnectedView(controller: controller);
          } else {
            body = Column(
              children: [
                // v5.42+：电脑端升级横幅（管理员手机端收到服务器推送后显示，
                // 可远程确认电脑端静默升级；三态：提示中/已通知/失败）
                if (controller.desktopUpgrade != null)
                  _DesktopUpgradeBanner(controller: controller),
                Expanded(
                  child: IndexedStack(
                    // 共享访客模式隐藏「上传」页签（_tab==1）：显示浏览页
                    index: controller.isShareGuest && _tab == 1 ? 0 : _tab,
                    children: [
                      _BrowseTab(controller: controller),
                      _UploadTab(controller: controller),
                      _TransfersTab(controller: controller),
                    ],
                  ),
                ),
              ],
            );
          }
          // v5.45+：后台横幅通知置顶于所有状态视图之上（连接引导/丢失重连/已连接）
          return Column(
            children: [
              if (controller.currentAdminNotice != null)
                _AdminNoticeBanner(controller: controller),
              // v5.46+：广告位（内容区顶部，所有状态/页签均可见；后台可配置）
              if (controller.showAd) _AdBanner(controller: controller),
              Expanded(child: body),
            ],
          );
        },
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final guest = controller.isShareGuest;
          return NavigationBar(
            selectedIndex: guest ? (_tab >= 2 ? 1 : 0) : _tab,
            onDestinationSelected: (i) {
              // 共享访客模式无「上传」页签：导航索引映射回真实页签
              setState(() => _tab = guest ? (i == 1 ? 2 : 0) : i);
              if (_tab == 0) controller.requestFileList();
            },
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '浏览'),
              if (!guest)
                const NavigationDestination(
                    icon: Icon(Icons.upload_outlined),
                    selectedIcon: Icon(Icons.upload),
                    label: '上传'),
              const NavigationDestination(
                  icon: Icon(Icons.swap_vert_outlined),
                  selectedIcon: Icon(Icons.swap_vert),
                  label: '传输'),
            ],
          );
        },
      ),
    );
  }
}

/// 更多菜单项：图标 + 文字（v5.1 低频操作收纳进 ⋮ 菜单）
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey.shade700),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}

class _ConnBadge extends StatelessWidget {
  final AppController controller;

  const _ConnBadge({required this.controller});

  @override
  Widget build(BuildContext context) {
    final type = controller.connectionType;
    // relay=服务器中转(橙) / direct=P2P直连(绿) / unknown=探测未完成(灰，中性展示)
    final relay = type == 'relay';
    final direct = type == 'direct';
    final color = relay
        ? Colors.orange
        : (direct ? Colors.green : Colors.grey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        controller.connTypeLabel,
        style: TextStyle(
          fontSize: 10,
          color: color,
        ),
      ),
    );
  }
}

/// 后台横幅通知（v5.45+）：服务器管理后台推送，任何连接状态下均显示；
/// 多条通知依次展示，关闭一条后自动显示下一条（内存队列最多 5 条）
class _AdminNoticeBanner extends StatelessWidget {
  final AppController controller;

  const _AdminNoticeBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    final n = controller.currentAdminNotice;
    if (n == null) return const SizedBox.shrink();
    final color = Colors.blue;
    return Material(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            const Icon(Icons.campaign_outlined, color: Colors.blue, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(n.title,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue)),
                  if (n.message.isNotEmpty)
                    Text(n.message,
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade700)),
                ],
              ),
            ),
            IconButton(
              tooltip: '关闭通知',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18, color: Colors.blueGrey),
              onPressed: () => controller.dismissAdminNotice(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 广告位（v5.46+）：管理后台配置（图片/文字/链接），内容区顶部展示；
/// 有图片显示图片卡，无图片显示文字卡；有链接点击打开；右上角可关闭（本次运行内）
class _AdBanner extends StatelessWidget {
  final AppController controller;

  const _AdBanner({required this.controller});

  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (e) {
      AppLog.w('ads', '打开广告链接失败: $url', e);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法打开链接: $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ad = controller.ad;
    if (ad == null) return const SizedBox.shrink();
    final orange = const Color(0xFFF59E0B);
    final textCard = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.campaign_outlined, size: 20, color: Colors.orange),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(ad.title,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.orange),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (ad.hasLink)
                      const Icon(Icons.open_in_new,
                          size: 13, color: Colors.blueGrey),
                  ],
                ),
                if (ad.message.isNotEmpty)
                  Text(ad.message,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade700,
                          height: 1.3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
    return Material(
      color: orange.withValues(alpha: 0.08),
      child: Stack(
        children: [
          InkWell(
            onTap: ad.hasLink ? () => _openLink(context, ad.linkUrl) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ad.hasImage)
                  SizedBox(
                    height: 90,
                    child: Image.network(
                      ad.imageUrl,
                      fit: BoxFit.cover,
                      // 加载中显示灰色占位，加载失败降级为文字卡
                      loadingBuilder: (c, child, progress) =>
                          progress == null
                              ? child
                              : Container(color: Colors.grey.shade200),
                      errorBuilder: (c, e, s) => textCard,
                    ),
                  ),
                if (!ad.hasImage) textCard,
              ],
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: '关闭广告',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18, color: Colors.blueGrey),
              onPressed: () => controller.dismissAd(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 电脑端升级横幅（v5.42+）：管理员手机端收到服务器推送后显示，
/// 可远程确认电脑端升级；三态：notify=提示中 / confirmed=已通知 / failed=失败
class _DesktopUpgradeBanner extends StatelessWidget {
  final AppController controller;

  const _DesktopUpgradeBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    final up = controller.desktopUpgrade;
    if (up == null) return const SizedBox.shrink();
    IconData icon;
    Color color;
    String title;
    String detail;
    switch (up.status) {
      case 'confirmed':
        icon = Icons.check_circle_outline;
        color = Colors.green;
        title = '已通知电脑端升级到 v${up.latest}';
        detail = '电脑将自动下载并重启，请留意电脑端运行状态';
      case 'failed':
        icon = Icons.error_outline;
        color = Colors.red;
        title = '电脑端升级失败';
        detail = up.error ?? '升级失败，请到电脑前手动处理';
      default:
        icon = up.urgent
            ? Icons.warning_amber_outlined
            : Icons.system_update_alt;
        color = const Color(0xFFF59E0B);
        title = '电脑端（${up.hostName}）有新版本 v${up.latest}';
        detail = '当前版本 v${up.current}，可在手机上远程确认升级';
    }
    return Material(
      color: color.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: color)),
                  if (detail.isNotEmpty)
                    Text(detail,
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                ],
              ),
            ),
            if (up.status == 'notify')
              FilledButton(
                onPressed: controller.confirmDesktopUpgrade,
                style: FilledButton.styleFrom(
                  backgroundColor: color,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                ),
                child: const Text('确认升级', style: TextStyle(fontSize: 12)),
              ),
            IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close, size: 18),
              onPressed: controller.dismissDesktopUpgrade,
            ),
          ],
        ),
      ),
    );
  }
}

/// 未连接引导视图：不连接电脑也可进入主页面，
/// 需要电脑端功能时点击「连接电脑」进入连接页手动连接
class _NotConnectedView extends StatelessWidget {
  final AppController controller;

  const _NotConnectedView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    final connecting = s == ConnectState.connecting || s == ConnectState.paired;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connecting)
              const CircularProgressIndicator()
            else
              Icon(Icons.link_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              connecting ? '正在连接电脑…' : '未连接电脑',
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              connecting
                  ? '请稍候'
                  : (controller.errorMessage ??
                      '连接电脑后可浏览/传输文件，\n也可查看分享给你的共享文件夹'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 20),
            if (!connecting)
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ConnectPage(
                        controller: controller, autoConnect: false),
                  ));
                },
                icon: const Icon(Icons.link),
                label: const Text('连接电脑'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 连接丢失视图
class _LostView extends StatelessWidget {
  final AppController controller;

  const _LostView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text(controller.errorMessage ?? '连接已断开',
              style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 4),
          const Text('正在自动重连，请保持电脑端开启…',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              // 断开自动重连，回到主页未连接视图；
              // 如需手动连接从主页「连接电脑」入口进入
              await controller.disconnect();
            },
            child: const Text('停止重连'),
          ),
        ],
      ),
    );
  }
}

/// 浏览页签
class _BrowseTab extends StatelessWidget {
  final AppController controller;

  const _BrowseTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final path = controller.dirPath;
    final segments = path.isEmpty ? <String>[] : path.split('/');

    // 共享访客模式（扫码共享连接）：只显示共享入口与引导，
    // 不展示「我的电脑」文件区（浏览/上传/删除主目录均无权限）
    if (controller.isShareGuest) {
      return Column(
        children: [
          // v5.30+：「共享空间」入口（访客模式常显，与 AppBar 收件箱图标同入口）
          if (AuthService.instance.activated || controller.isShareGuest)
            _shareFolderEntry(context, controller),
          if (controller.shares.isNotEmpty) _shareEntries(context, controller),
          Expanded(
            child: _MessageView(
              icon: Icons.folder_shared_outlined,
              text: controller.shares.isNotEmpty
                  ? '共享访问模式：点击上方共享文件夹浏览，\n只能操作分享给你的内容'
                  : '共享访问模式：暂无分享给你的共享文件夹',
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        // v5.30+：「共享空间」入口（浏览页常显，与 AppBar 收件箱图标同入口）
        if (AuthService.instance.activated || controller.isShareGuest)
          _shareFolderEntry(context, controller),
        // 共享目录入口（扫码加入的共享，点击进入共享浏览页）
        if (controller.shares.isNotEmpty) _shareEntries(context, controller),
        // 路径面包屑
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            children: [
              ActionChip(
                label: Text(controller.hostName ?? '远程电脑',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () => controller.navigateTo(-1),
              ),
              for (var i = 0; i < segments.length; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ActionChip(
                    label: Text(segments[i]),
                    onPressed: () => controller.navigateTo(i),
                  ),
                ),
            ],
          ),
        ),
        // 下载进度提示
        if (controller.activeDownloadName != null)
          DownloadBanner(controller: controller),
        // v5.25+：上传进度提示（上传页签之外也可见）
        if (controller.activeUploadName != null)
          UploadBanner(controller: controller),
        // 文件列表
        Expanded(child: _buildList(context, controller)),
      ],
    );
  }

  /// 「共享空间」入口卡片（v5.30+）：浏览页常显，点击进入「共享给我的」列表
  Widget _shareFolderEntry(BuildContext context, AppController controller) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.15),
          child: const Icon(Icons.inbox_outlined, color: Color(0xFF38BDF8)),
        ),
        title: const Text('共享空间',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        subtitle: const Text('从其他电脑分享给你的内容',
            style: TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ShareCenterPage(controller: controller)));
        },
      ),
    );
  }

  /// 共享目录入口列表（横向 chips）
  Widget _shareEntries(BuildContext context, AppController controller) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          for (final s in controller.shares)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: const Icon(Icons.folder_shared,
                    size: 16, color: Color(0xFF0D9488)),
                label: Text(s.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onPressed: () {
                  controller.openShare(s);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          ShareBrowsePage(controller: controller)));
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, AppController controller) {
    if (controller.listLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.listError != null) {
      return _MessageView(
        icon: Icons.error_outline,
        text: controller.listError!,
      );
    }
    if (controller.files.isEmpty) {
      return const _MessageView(
        icon: Icons.folder_off_outlined,
        text: '此目录为空',
      );
    }
    return RefreshIndicator(
      onRefresh: () => controller.requestFileList(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: controller.files.length,
        itemBuilder: (context, i) {
          final f = controller.files[i];
          return _FileTile(
            entry: f,
            onTap: () {
              if (f.isDirectory) {
                controller.openDir(f);
              } else {
                controller.downloadFile(f);
              }
            },
            // 删除等危险操作不常显在列表中（防误触），改为长按弹出操作菜单
            onLongPress: () => _showFileActions(context, controller, f),
            onPlay: !f.isDirectory && isVideoFile(f.name)
                ? () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => VideoPlayerPage(
                          controller: controller, entry: f),
                    ));
                  }
                : null,
          );
        },
      ),
    );
  }
  /// 长按文件操作菜单（防误触：删除等危险操作不再常显在列表中）
  Future<void> _showFileActions(
      BuildContext context, AppController controller, FileEntry f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                f.isDirectory ? Icons.folder : Icons.insert_drive_file,
                color: f.isDirectory
                    ? const Color(0xFFF59E0B)
                    : const Color(0xFF38BDF8),
              ),
              title: Text(f.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: f.isDirectory
                  ? null
                  : Text(formatSize(f.size ?? 0),
                      style: const TextStyle(fontSize: 12)),
            ),
            if (!f.isDirectory)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('下载'),
                onTap: () => Navigator.of(ctx).pop('download'),
              ),
            if (!f.isDirectory && isVideoFile(f.name))
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('在线播放'),
                onTap: () => Navigator.of(ctx).pop('play'),
              ),
            if (controller.isAdmin)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Colors.redAccent),
                title: const Text('删除',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'download') controller.downloadFile(f);
    if (action == 'play') {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
            controller: controller, entry: f),
      ));
    }
    if (action == 'delete') _confirmDelete(context, controller, f);
  }

  /// 删除确认对话框（主目录仅管理员有删除权限）
  Future<void> _confirmDelete(
      BuildContext context, AppController controller, FileEntry f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除确认'),
        content: Text(
            '确定删除「${f.name}」吗？${f.isDirectory ? '目录将递归删除。' : ''}此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) controller.deleteFile(f);
  }
}

class _FileTile extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final VoidCallback? onLongPress;

  const _FileTile(
      {required this.entry,
      required this.onTap,
      this.onPlay,
      this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
        color: entry.isDirectory ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8),
        size: 32,
      ),
      title: Text(entry.name,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: entry.isDirectory
          ? null
          : Text(formatSize(entry.size ?? 0),
              style: const TextStyle(fontSize: 12)),
      trailing: entry.isDirectory
          ? const Icon(Icons.chevron_right)
          : (onPlay != null
              ? IconButton(
                  icon: const Icon(Icons.play_circle_fill,
                      color: Color(0xFF38BDF8),
                      size: 32),
                  tooltip: '在线播放',
                  onPressed: onPlay,
                )
              : null),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// 上传页签
class _UploadTab extends StatefulWidget {
  final AppController controller;

  const _UploadTab({required this.controller});

  @override
  State<_UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<_UploadTab> {
  final List<PlatformFile> _picked = [];
  String? _lastConflictShown; // 已弹窗的冲突文件，避免重复弹窗
  bool _applyAll = false; // 对本次所有重名文件同样处理（弹窗内勾选）
  bool _processingPick = false; // 文件选择器正在读取所选文件（大文件耗时较长）

  /// 选择文件：支持多次追加（自动去重），避免系统选择器单选限制
  /// Android 上 file_picker 每次选择会复制到缓存目录、path 每次都不同，
  /// 故用 name + size 判断重复（同一文件大小必然相同）
  Future<void> _pickFiles() async {
    // 大文件选择后需复制到缓存目录，先显示处理中提示，避免用户误以为没选上
    setState(() => _processingPick = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) {
        AppLog.i('upload', '文件选择器取消，未选择文件');
        return;
      }
      var added = 0;
      setState(() {
        for (final f in result.files) {
          final dup = _picked.any(
              (p) => p.name == f.name && p.size == f.size);
          if (!dup) {
            _picked.add(f);
            added++;
          }
        }
      });
      AppLog.i('upload',
          '选择文件: 新选$added个(已选${_picked.length}个), 合计${_picked.fold<int>(0, (s, f) => s + f.size)}B');
    } finally {
      if (mounted) setState(() => _processingPick = false);
    }
  }

  /// 选择上传目标目录（电脑端共享目录下的子目录）
  Future<void> _pickUploadDir() async {
    widget.controller.refreshUploadDirs();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _UploadDirDialog(controller: widget.controller),
    );
  }

  /// 重名冲突弹窗（由 controller.pendingConflict 触发）
  void _checkConflict(AppController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final req = controller.pendingConflict;
      if (req == null || req.fileName == _lastConflictShown) return;
      _lastConflictShown = req.fileName;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('文件名重复'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    '电脑端已存在同名文件「${req.fileName}」\n请选择处理方式：'),
                CheckboxListTile(
                  value: _applyAll,
                  onChanged: (v) =>
                      setDialogState(() => _applyAll = v ?? false),
                  title: const Text('对本次上传的其他重名文件同样处理'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  controller.resolveConflict('skip', applyAll: _applyAll);
                  Navigator.of(ctx).pop();
                },
                child: const Text('跳过'),
              ),
              TextButton(
                onPressed: () {
                  controller.resolveConflict('rename', applyAll: _applyAll);
                  Navigator.of(ctx).pop();
                },
                child: const Text('另存为'),
              ),
              FilledButton(
                onPressed: () {
                  controller
                      .resolveConflict('overwrite', applyAll: _applyAll);
                  Navigator.of(ctx).pop();
                },
                child: const Text('覆盖'),
              ),
            ],
          ),
        ),
      ).then((_) {
        // 弹窗关闭后重置去重标记：同一批中多个同名文件需依次弹窗决策
        _lastConflictShown = null;
        _applyAll = false;
      });
    });
  }

  Future<void> _upload() async {
    if (_picked.isEmpty) return;
    final ok = await widget.controller.startUpload(_picked);
    if (!mounted) return;
    final fail = _picked.length - ok;
    setState(() => _picked.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fail > 0
              ? '上传完成: $ok 个成功, $fail 个失败(见传输记录)'
              : '上传完成: $ok 个文件已发送',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final busy = controller.uploading;
    _checkConflict(controller);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _pickUploadDir,
                icon: const Icon(Icons.folder_copy_outlined),
                label: Text(
                  '上传到: ${controller.uploadDirPath.isEmpty ? (controller.hostName ?? '远程电脑') : controller.uploadDirPath}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy || _processingPick ? null : _pickFiles,
                icon: const Icon(Icons.attach_file),
                label: Text(busy || _processingPick
                    ? '正在读取所选文件…'
                    : '选择要上传的文件'),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
              if (_processingPick)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: const [
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('正在读取所选文件，大文件需要一点时间，请稍候…',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                    ],
                  ),
                ),
              if (_picked.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '已选 ${_picked.length} 个文件',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => _picked.clear()),
                      child: const Text('清空'),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < _picked.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(Icons.description_outlined,
                                  size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_picked[i].name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                              Text(formatSize(_picked[i].size),
                                  style: const TextStyle(fontSize: 12)),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                visualDensity: VisualDensity.compact,
                                tooltip: '移除',
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                        () => _picked.removeAt(i)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '可再次点「选择要上传的文件」继续添加',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: busy ? null : _upload,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.upload),
                  label: Text(busy
                      ? '上传中...'
                      : '开始上传 (${_picked.length})'),
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
                if (busy && controller.connectionType.isNotEmpty) ...[  // 上传时显示当前传输方式
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('当前传输方式:',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(width: 6),
                      ConnChip(label: controller.connTypeLabel),
                    ],
                  ),
                ],
              ],
              if (controller.errorMessage != null &&
                  controller.errorMessage!.contains('保存'))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    controller.errorMessage!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _TransfersTab(controller: controller, filter: 'upload'),
        ),
      ],
    );
  }
}

/// 上传目标目录选择对话框（浏览电脑端共享目录树）
class _UploadDirDialog extends StatefulWidget {
  final AppController controller;

  const _UploadDirDialog({required this.controller});

  @override
  State<_UploadDirDialog> createState() => _UploadDirDialogState();
}

class _UploadDirDialogState extends State<_UploadDirDialog> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final segments = controller.uploadDirPath.isEmpty
        ? <String>[]
        : controller.uploadDirPath.split('/');

    return AlertDialog(
      title: const Text('选择上传目录'),
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: [
              // 路径面包屑
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    ActionChip(
                      label: Text(controller.hostName ?? '远程电脑',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onPressed: () => controller.navigateUploadDir(-1),
                    ),
                    for (var i = 0; i < segments.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: ActionChip(
                          label: Text(segments[i]),
                          onPressed: () => controller.navigateUploadDir(i),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // 子目录列表
              Expanded(
                child: controller.uploadDirLoading
                    ? const Center(child: CircularProgressIndicator())
                    : controller.uploadDirs.isEmpty
                        ? const Center(
                            child: Text('此目录下没有子目录',
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView.builder(
                            itemCount: controller.uploadDirs.length,
                            itemBuilder: (context, i) {
                              final d = controller.uploadDirs[i];
                              if (!d.isDirectory) {
                                return const SizedBox.shrink();
                              }
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.folder,
                                    color: Color(0xFFF59E0B)),
                                title: Text(d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                onTap: () =>
                                    controller.openUploadDir(d),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
              '上传到此目录 (${segments.isEmpty ? (controller.hostName ?? '远程电脑') : controller.uploadDirPath})'),
        ),
      ],
    );
  }
}

/// 传输记录页签
class _TransfersTab extends StatefulWidget {
  final AppController controller;
  final String? filter;

  const _TransfersTab({required this.controller, this.filter});

  @override
  State<_TransfersTab> createState() => _TransfersTabState();
}

class _TransfersTabState extends State<_TransfersTab> {
  /// v5.38+ 多选删除：是否处于选择模式
  bool _selecting = false;
  /// 已勾选的记录 id 集合
  final Set<String> _selected = {};

  List<TransferItem> get _items => widget.filter == null
      ? widget.controller.transfers
      : widget.controller.transfers
          .where((t) => t.direction == widget.filter)
          .toList();

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) {
      // 列表被删空时退出选择模式，避免残留选择栏
      if (_selecting) {
        _selecting = false;
        _selected.clear();
      }
      return const _MessageView(
        icon: Icons.history,
        text: '暂无传输记录',
      );
    }
    return Column(
      children: [
        if (_selecting) _buildSelectBar(context),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              // 显示本次传输时的连接方式（记录快照）：已完成的记录固定显示传输时的方式；
              // 进行中且探测尚未完成（unknown）时回退显示当前方式
              String? connLabel;
              if (item.connType == 'relay') {
                connLabel = '服务器中转';
              } else if (item.connType == 'direct') {
                connLabel = 'P2P直连';
              } else if (item.status == 'transferring') {
                connLabel = widget.controller.connTypeLabel;
              }
              final selected = _selected.contains(item.id);
              return GestureDetector(
                // v5.38+ 选择模式点选切换；非选择模式长按进入选择并勾选该条
                onTap: _selecting ? () => _toggleSelect(item.id) : null,
                onLongPress: _selecting ? null : () => _enterSelect(item.id),
                child: _TransferTile(
                  item: item,
                  connLabel: connLabel,
                  selecting: _selecting,
                  selected: selected,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 选择模式操作栏：已选 n 项 + 全选/删除/取消
  Widget _buildSelectBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.25),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '已选 ${_selected.length} 项',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => _selectAll(),
              child: const Text('全选'),
            ),
            TextButton(
              onPressed:
                  _selected.isEmpty ? null : () => _confirmBatchDelete(context),
              child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(
              onPressed: _exitSelect,
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
  }

  /// 非选择模式长按：进入选择模式并勾选该条
  void _enterSelect(String id) {
    setState(() {
      _selecting = true;
      _selected.add(id);
    });
  }

  /// 选择模式点选：切换勾选状态
  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  /// 全选/取消全选（按当前列表全部记录）
  void _selectAll() {
    setState(() {
      final all = _items.map((t) => t.id).toSet();
      if (_selected.length == all.length && _selected.containsAll(all)) {
        _selected.clear(); // 已全选：再次点击取消全选
      } else {
        _selected
          ..clear()
          ..addAll(all);
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// 批量删除确认弹窗：确认后逐条删除（含持久化）并退出选择模式
  Future<void> _confirmBatchDelete(BuildContext context) async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除传输记录'),
        content: Text('确定删除选中的 $n 条传输记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      for (final id in _selected.toList()) {
        widget.controller.removeTransfer(id);
      }
      _exitSelect();
    }
  }
}

class _TransferTile extends StatelessWidget {
  final TransferItem item;
  final String? connLabel; // 传输时的连接方式（直连/服务器中转）
  final bool selecting; // v5.38+ 选择模式：leading 显示勾选圈
  final bool selected; // v5.38+ 当前记录是否已勾选

  const _TransferTile({
    required this.item,
    this.connLabel,
    this.selecting = false,
    this.selected = false,
  });

  /// v5.37+ 副标题：进行中显示进度+速度；终态显示体积/完成时间/传输对象电脑端名称
  String _subtitleText(TransferItem item, bool done, bool error, bool skipped) {
    final peer = item.peerName.isNotEmpty ? item.peerName : '电脑';
    final end = item.endTime;
    final endStr = end == null
        ? ''
        : '${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')} '
            '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    if (skipped) return '已跳过（电脑端存在同名文件）';
    if (done) {
      return '${formatSize(item.total)}'
          '${endStr.isNotEmpty ? ' · 完成于 $endStr' : ''} · $peer';
    }
    if (error) {
      final size = '${formatSize(item.transferred)} / ${formatSize(item.total)}';
      return '$size'
          '${endStr.isNotEmpty ? ' · 失败于 $endStr' : ''} · $peer';
    }
    return '${formatSize(item.transferred)} / ${formatSize(item.total)}'
        '${item.speed.isNotEmpty ? '  ${item.speed}' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final isUpload = item.direction == 'upload';
    final done = item.status == 'done';
    final error = item.status == 'error';
    final skipped = item.status == 'skipped';

    return ListTile(
      // 选择模式下勾选的行浅色高亮（v5.38+）
      tileColor: selected ? Colors.blue.withOpacity(0.08) : null,
      leading: selecting
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? Colors.blue : Colors.grey,
            )
          : Icon(
              skipped
                  ? Icons.skip_next
                  : isUpload
                      ? Icons.upload
                      : Icons.download,
              color: error
                  ? Colors.redAccent
                  : done
                      ? Colors.green
                      : skipped
                          ? Colors.orange
                          : Colors.blue,
            ),
      title: Row(
        children: [
          Expanded(
            child:
                Text(item.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          // 连接方式彩色徽标（醒目标题行）：绿=点对点直连 橙=服务器中转
          if (connLabel != null && connLabel!.isNotEmpty) ...[
            const SizedBox(width: 6),
            ConnChip(label: connLabel!),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          if (!done && !error && !skipped)
            LinearProgressIndicator(value: item.progress, minHeight: 4),
          const SizedBox(height: 4),
          Text(
            _subtitleText(item, done, error, skipped),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      trailing: Icon(
        error
            ? Icons.error_outline
            : done
                ? Icons.check_circle
                : skipped
                    ? Icons.remove_circle_outline
                    : Icons.sync,
        size: 20,
        color: error
            ? Colors.redAccent
            : done
                ? Colors.green
                : skipped
                    ? Colors.orange
                    : Colors.grey,
      ),
    );
  }
}

/// 连接方式徽标：绿=点对点直连 橙=服务器中转（v5.24+ 已迁移至 download_banner.dart 公共组件）

/// 通用提示视图
class _MessageView extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MessageView({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
