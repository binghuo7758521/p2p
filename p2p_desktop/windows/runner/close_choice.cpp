// 关闭窗口行为选择框（v6.10）
//
// 本机系统 comctl32.dll 为精简版：TaskDialog 系列导出被裁剪
// （无序数 345），链接 comctl32.lib 会导致 exe 启动即报
// 「无法定位序数 345」。因此选择框不使用 TaskDialogIndirect，
// 改为手动创建 Win32 模态对话框：
// - 按钮用标准 BS_PUSHBUTTON（BS_COMMANDLINK 依赖视觉样式绘制，
//   精简版系统上按钮控件存在但不可见）
// - 「记住我的选择」复选框 + 取消（Esc/关闭按钮）行为完整保留
#include "close_choice.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

constexpr UINT kCmdMinimize = 1001;
constexpr UINT kCmdQuit = 1002;
constexpr UINT kChkRemember = 1003;

// 记忆文件：%APPDATA%\p2p_desktop\close_action（与备注名同目录）
std::wstring FilePath() {
  wchar_t buf[MAX_PATH] = {};
  if (::GetEnvironmentVariableW(L"APPDATA", buf, MAX_PATH) == 0) {
    return L"";
  }
  return std::wstring(buf) + L"\\p2p_desktop\\close_action";
}

// —— 模态选择框状态（程序为单实例，静态变量安全）——
HWND g_hDlg = nullptr;
HWND g_hCheck = nullptr;
close_choice::Action g_result = close_choice::Action::Ask;

int DpiScale(int v) {
  HDC dc = ::GetDC(nullptr);
  const int dpi = dc ? ::GetDeviceCaps(dc, LOGPIXELSX) : 96;
  if (dc) ::ReleaseDC(nullptr, dc);
  return ::MulDiv(v, dpi, 96);
}

HFONT MakeFont(int pt) {
  // pt → 像素高（负值表示按字符高度计算）
  const int h = -DpiScale(pt * 96 / 72);
  return ::CreateFontW(h, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                       DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
}

void Finish(close_choice::Action action) {
  g_result = action;
  const bool checked =
      g_hCheck && ::SendMessageW(g_hCheck, BM_GETCHECK, 0, 0) == BST_CHECKED;
  // 勾选「记住我的选择」且确实做了选择时才落盘；取消不触碰记忆文件
  if (checked && action != close_choice::Action::Ask) {
    close_choice::Save(action, true);
  }
  ::DestroyWindow(g_hDlg);
  g_hDlg = nullptr;
}

LRESULT CALLBACK ChoiceWndProc(HWND hwnd, UINT msg, WPARAM wParam,
                               LPARAM lParam) {
  switch (msg) {
    case WM_COMMAND: {
      const UINT id = LOWORD(wParam);
      if (id == kCmdMinimize) {
        Finish(close_choice::Action::Minimize);
      } else if (id == kCmdQuit) {
        Finish(close_choice::Action::Quit);
      }
      return 0;
    }
    case WM_CLOSE:  // 点 X / Esc 视为取消：窗口保持打开
      Finish(close_choice::Action::Ask);
      return 0;
    default:
      return ::DefWindowProcW(hwnd, msg, wParam, lParam);
  }
}

close_choice::Action ShowChoiceDialog(HWND parent) {
  g_hDlg = nullptr;
  g_hCheck = nullptr;
  g_result = close_choice::Action::Ask;

  const HINSTANCE inst = ::GetModuleHandleW(nullptr);
  static bool registered = false;
  if (!registered) {
    WNDCLASSW wc = {};
    wc.lpfnWndProc = ChoiceWndProc;
    wc.hInstance = inst;
    wc.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"P2PCloseChoiceDlg";
    const ATOM a = ::RegisterClassW(&wc);
    registered = a != 0;
  }

  // 客户区目标尺寸；AdjustWindowRectEx 把标题栏/边框算进窗口总高
  // （否则底部控件会被裁剪）
  const int cw = DpiScale(400);
  const int ch = DpiScale(204);
  RECT wr = {0, 0, cw, ch};
  ::AdjustWindowRectEx(&wr, WS_CAPTION | WS_SYSMENU | WS_OVERLAPPED, FALSE,
                       WS_EX_DLGMODALFRAME);
  const int w = wr.right - wr.left;
  const int h = wr.bottom - wr.top;
  RECT pr = {};
  ::GetWindowRect(parent, &pr);
  const int x = pr.left + (pr.right - pr.left - w) / 2;
  const int y = pr.top + (pr.bottom - pr.top - h) / 3;

  HWND dlg = ::CreateWindowExW(
      WS_EX_DLGMODALFRAME, L"P2PCloseChoiceDlg", L"无限大盘",
      WS_CAPTION | WS_SYSMENU | WS_OVERLAPPED | WS_VISIBLE, x, y, w, h,
      parent, nullptr, inst, nullptr);
  if (!dlg) return close_choice::Action::Ask;
  g_hDlg = dlg;

  HFONT font = MakeFont(9);
  HFONT titleFont = MakeFont(12);

  auto mk = [&](const wchar_t* cls, const wchar_t* text, DWORD style, int x_,
                int y_, int w_, int h_, UINT id) {
    return ::CreateWindowExW(
        0, cls, text, WS_CHILD | WS_VISIBLE | style, DpiScale(x_), DpiScale(y_),
        DpiScale(w_), DpiScale(h_), dlg,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), inst, nullptr);
  };

  HWND title = mk(L"STATIC", L"关闭窗口后希望如何操作？", SS_LEFT, 16, 14, 368,
                  22, 0);
  HWND desc =
      mk(L"STATIC",
         L"最小化到托盘：程序继续在后台运行，收发文件不受影响。\n"
         L"退出应用：结束全部进程，不再接收文件。",
         SS_LEFT, 16, 42, 368, 40, 0);
  g_hCheck = mk(L"BUTTON", L"记住我的选择，下次不再询问",
                BS_AUTOCHECKBOX | WS_TABSTOP, 16, 88, 368, 20, kChkRemember);
  HWND btnMin =
      mk(L"BUTTON", L"最小化到托盘", BS_PUSHBUTTON | WS_TABSTOP, 32, 116,
         336, 34, kCmdMinimize);
  HWND btnQuit =
      mk(L"BUTTON", L"退出应用", BS_PUSHBUTTON | WS_TABSTOP, 32, 156, 336,
         34, kCmdQuit);

  const HWND kids[] = {title, desc, g_hCheck, btnMin, btnQuit};
  for (HWND c : kids) {
    ::SendMessageW(c, WM_SETFONT,
                   reinterpret_cast<WPARAM>(c == title ? titleFont : font),
                   TRUE);
  }

  // 模态：禁用父窗口，本地消息循环（Flutter 引擎的定时器消息仍正常分发）
  ::EnableWindow(parent, FALSE);
  ::SetForegroundWindow(dlg);
  ::SetFocus(g_hCheck);

  MSG msg;
  while (::IsWindow(dlg)) {
    while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {  // 主程序正在退出：放弃弹框
        ::DestroyWindow(dlg);
        g_hDlg = nullptr;
        g_result = close_choice::Action::Ask;
        break;
      }
      if (!::IsDialogMessageW(dlg, &msg)) {
        ::TranslateMessage(&msg);
        ::DispatchMessageW(&msg);
      }
    }
    if (!g_hDlg) break;
    ::WaitMessage();
  }

  ::EnableWindow(parent, TRUE);
  ::SetForegroundWindow(parent);
  return g_result;
}

}  // namespace

namespace close_choice {

Action HandleClose(HWND hwnd) {
  const std::wstring path = FilePath();
  if (!path.empty()) {
    FILE* f = nullptr;
    if (_wfopen_s(&f, path.c_str(), L"rb") == 0 && f != nullptr) {
      char buf[32] = {};
      const size_t n = fread(buf, 1, sizeof(buf) - 1, f);
      fclose(f);
      buf[n] = '\0';
      if (strcmp(buf, "minimize") == 0) return Action::Minimize;
      if (strcmp(buf, "quit") == 0) return Action::Quit;
    }
  }

  // 无记忆：弹选择框（最小化到托盘 / 退出应用，可勾选记住）
  return ShowChoiceDialog(hwnd);
}

void Save(Action action, bool remember) {
  const std::wstring path = FilePath();
  if (path.empty()) return;
  const size_t pos = path.find_last_of(L'\\');
  if (pos == std::wstring::npos) return;
  // 确保目录存在（与备注名等配置共用 %APPDATA%\p2p_desktop）
  ::CreateDirectoryW(path.substr(0, pos).c_str(), nullptr);

  if (action == Action::Ask || !remember) {
    ::DeleteFileW(path.c_str());
    return;
  }
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"wb") != 0 || f == nullptr) return;
  const char* content = action == Action::Minimize ? "minimize" : "quit";
  fwrite(content, 1, strlen(content), f);
  fclose(f);
}

}  // namespace close_choice
