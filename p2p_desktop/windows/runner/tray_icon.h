#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

// 托盘回调消息 ID（FlutterWindow::MessageHandler 据此分发到 TrayIcon）
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// 系统托盘图标（Shell_NotifyIcon 实现）
//
// 交互约定：
// - 点击关闭按钮 → 隐藏主窗口到托盘（程序继续后台运行）
// - 双击托盘图标 → 恢复显示主窗口
// - 右键托盘图标 → 弹出「退出系统」菜单（唯一彻底退出途径）
class TrayIcon {
 public:
  // 创建托盘图标（主窗口创建成功后调用，owner 为主窗口句柄）
  bool Create(HWND owner);

  // 删除托盘图标（主窗口销毁时调用）
  void Destroy();

  // 处理托盘回调消息（FlutterWindow 收到 kTrayCallbackMessage 时调用）
  void HandleMessage(WPARAM wparam, LPARAM lparam);

  // 隐藏主窗口到托盘（点击关闭按钮时调用），并弹出气泡提示告知用户
  void HideMainWindow();

 private:
  HWND owner_ = nullptr;
  bool created_ = false;

  // 弹出右键菜单并执行选中动作（当前仅「退出系统」）
  void ShowContextMenu();

  // 恢复显示主窗口并置前激活
  void ShowMainWindow();
};

#endif  // RUNNER_TRAY_ICON_H_
