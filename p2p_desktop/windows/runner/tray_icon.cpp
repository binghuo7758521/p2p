#include "tray_icon.h"

#include <shellapi.h>

#include "resource.h"

namespace {
constexpr UINT kTrayIconId = 1;
constexpr UINT kMenuExitId = 1001;
}  // namespace

bool TrayIcon::Create(HWND owner) {
  if (created_) {
    return true;
  }
  owner_ = owner;

  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(NOTIFYICONDATAW);
  nid.hWnd = owner_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayCallbackMessage;
  nid.hIcon =
      ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(nid.szTip, L"无限大盘");

  created_ = ::Shell_NotifyIconW(NIM_ADD, &nid) == TRUE;
  return created_;
}

void TrayIcon::Destroy() {
  if (!created_) {
    return;
  }
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(NOTIFYICONDATAW);
  nid.hWnd = owner_;
  nid.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &nid);
  created_ = false;
}

void TrayIcon::HandleMessage(WPARAM wparam, LPARAM lparam) {
  if (wparam != kTrayIconId) {
    return;
  }
  switch (LOWORD(lparam)) {
    case WM_LBUTTONDBLCLK:
      ShowMainWindow();
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowContextMenu();
      break;
    default:
      break;
  }
}

void TrayIcon::HideMainWindow() {
  if (!owner_) {
    return;
  }
  ::ShowWindow(owner_, SW_HIDE);

  // 气泡提示：告知用户程序仍在后台运行（每次隐藏都提示）
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(NOTIFYICONDATAW);
  nid.hWnd = owner_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO;
  wcscpy_s(nid.szInfoTitle, L"无限大盘");
  wcscpy_s(nid.szInfo, L"已最小化到系统托盘，双击托盘图标恢复窗口；\n右键图标可选择退出系统。");
  ::Shell_NotifyIconW(NIM_MODIFY, &nid);
}

void TrayIcon::ShowMainWindow() {
  if (!owner_) {
    return;
  }
  ::ShowWindow(owner_, SW_SHOW);
  ::SetForegroundWindow(owner_);
}

void TrayIcon::ShowContextMenu() {
  HMENU menu = ::CreatePopupMenu();
  ::AppendMenuW(menu, MF_STRING, kMenuExitId, L"退出系统");

  POINT pt = {};
  ::GetCursorPos(&pt);
  // TPM_RETURNCMD：直接返回选中的菜单项 ID（不向窗口发 WM_COMMAND）
  const UINT cmd = ::TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x,
                                    pt.y, 0, owner_, nullptr);
  if (cmd == kMenuExitId) {
    // 直接终止进程：flutter_windows.dll 引擎析构阶段存在崩溃风险
    // （详见 flutter_window.cpp WM_CLOSE 注释），沿用同一退出方案
    ::ExitProcess(0);
  }
  ::DestroyMenu(menu);
}
