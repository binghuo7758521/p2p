#ifndef RUNNER_CLOSE_CHOICE_H_
#define RUNNER_CLOSE_CHOICE_H_

#include <windows.h>

// 关闭窗口行为选择（v6.10）
//
// 首次点击关闭按钮时弹出原生选择框：最小化到托盘 / 退出应用，
// 用户可勾选「记住我的选择」持久化到 %APPDATA%\p2p_desktop\close_action，
// 之后点击关闭直接按记忆执行，不再弹窗。
//
// 记忆文件内容：minimize（隐藏到托盘）/ quit（退出应用）
// （与 Flutter 设置页共用同一文件，设置页三选一：每次询问/最小化/退出）
namespace close_choice {

// 关闭行为：ask=未记忆（每次询问）；minimize=隐藏到托盘；quit=退出应用
enum class Action { Ask, Minimize, Quit };

// 处理关闭窗口：读取记忆直接返回对应动作；无记忆时弹选择框。
// 返回 Ask 表示用户取消（窗口保持打开）。
Action HandleClose(HWND hwnd);

// 写入/清除记忆（供设置页与测试使用：Ask 时删除记忆文件）
void Save(Action action, bool remember);

}  // namespace close_choice

#endif  // RUNNER_CLOSE_CHOICE_H_
