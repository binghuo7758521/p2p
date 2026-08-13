#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // ── 单实例保护（命名互斥体）──────────────────────────
  // 在 Flutter 引擎初始化之前拦截：CreateMutexW 与 GetLastError 紧邻调用，
  // 无中间层，检测可靠（Dart FFI 版本的 GetLastError 会被 VM 运行时代码覆盖，
  // 导致双开，v5.4 已废弃 Dart 侧实现，统一在此处理）
  HANDLE mutex = ::CreateMutexW(
      nullptr, FALSE, L"Local\\P2P_Desktop_Single_Instance");
  (void)mutex;  // 句柄存活即可，进程退出时内核自动释放互斥体
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::MessageBoxW(
        nullptr,
        L"P2P 文件助手已在运行（可能最小化在任务栏/托盘中）。\n"
        L"请先关闭已打开的窗口，再重新启动程序。",
        L"P2P 文件助手", MB_OK | MB_ICONINFORMATION);
    return 0;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"p2p_desktop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // ── 窗口标题通道：dart 侧启动时设置 "p2p_desktop vX.Y"（版本号单一来源）──
  // 版本升级只需改 version.dart，窗口标题自动跟随，无需再改本文件
  flutter::MethodChannel<flutter::EncodableValue> title_channel(
      window.engine()->messenger(), "p2p/window_title",
      &flutter::StandardMethodCodec::GetInstance());
  title_channel.SetMethodCallHandler(
      [&window](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                    result) {
        if (call.method_name() == "set") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("title"));
            if (it != args->end() &&
                std::holds_alternative<std::string>(it->second)) {
              const auto& utf8 = std::get<std::string>(it->second);
              const int len = ::MultiByteToWideChar(
                  CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                  nullptr, 0);
              if (len > 0) {
                std::wstring title(len, L'\0');
                ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                      static_cast<int>(utf8.size()), &title[0],
                                      len);
                ::SetWindowTextW(window.GetHandle(), title.c_str());
              }
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
