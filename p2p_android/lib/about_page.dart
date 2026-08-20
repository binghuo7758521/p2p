import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'update_check.dart';
import 'version.dart';

/// 关于页（v5.39+）：显示版本信息、服务器地址、设备标识，支持手动检查更新
class AboutPage extends StatelessWidget {
  final AppController controller;

  const AboutPage({super.key, required this.controller});

  /// 手动检查更新：无新版本提示；有新版弹确认窗，可选立即下载安装
  Future<void> _checkUpdate(BuildContext context) async {
    final info = await checkAndroidUpdate();
    if (!context.mounted) return;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('检查更新失败，请检查网络连接')));
      return;
    }
    if (!info.needUpdate) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('当前已是最新版本 v$appVersion')));
      return;
    }
    // 强制升级：复用不可跳过的升级窗
    if (info.force) {
      await showForcedUpdateDialog(context, info);
      return;
    }
    // 普通更新：确认后进入下载安装流程
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
        title: Text('发现新版本 v${info.latest}'),
        content: Text(
            '当前版本 v$appVersion\n\n${info.notes.isEmpty ? '是否立即更新？' : info.notes}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('later'),
              child: const Text('稍后')),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop('download'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('立即更新'),
          ),
        ],
      ),
    );
    if (action != 'download' || !context.mounted) return;
    if (info.url == null) return;
    await _downloadAndInstall(context, info.url!, expectedMd5: info.md5);
  }

  /// 下载升级包并拉起系统安装器（与主页升级流程一致的进度提示）
  Future<void> _downloadAndInstall(BuildContext context, String url,
      {String? expectedMd5}) async {
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
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 关闭进度对话框
    // 按安装结果提示（与启动升级提示一致）
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
    final connected = controller.state == ConnectState.peerConnected;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 应用头部
          const SizedBox(height: 8),
          Center(
            child: Column(
              children: [
                Image.asset('assets/logo.png',
                    width: 64, height: 64, fit: BoxFit.contain),
                const SizedBox(height: 12),
                Text('无限大盘',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('v$appVersion',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.primary)),
                const SizedBox(height: 4),
                Text('P2P 文件传输助手',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 信息列表
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.5),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('版本号'),
                  trailing: Text('v$appVersion',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.primary)),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器地址'),
                  trailing: Text(
                    controller.lastServerUrl ?? defaultServerUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.devices_outlined),
                  title: const Text('设备标识'),
                  subtitle: Text(controller.deviceId,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    connected ? Icons.link : Icons.link_off,
                    color: connected ? Colors.green : Colors.redAccent,
                  ),
                  title: const Text('连接状态'),
                  trailing: Text(
                    connected
                        ? '已连接：${controller.hostName ?? '电脑'}'
                        : '未连接',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 检查更新
          FilledButton.icon(
            onPressed: () => _checkUpdate(context),
            icon: const Icon(Icons.system_update_alt),
            label: const Text('检查更新'),
          ),
          const SizedBox(height: 32),
          Center(
            child: Text('© 2026 无限大盘',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}
