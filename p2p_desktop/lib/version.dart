/// 版本号（调试时确认是否最新版本）
///
/// 规则: 手机端 / 电脑端 / 服务器端 三端版本互相独立（vX.Y）
/// - 只要电脑端代码有修改，本端版本号 +0.1（v1.0 → v1.1 → v1.2 ...）
/// - server.js 中的 DESKTOP_VERSION 需与本端保持一致，便于 /version 核对
const String appVersion = '6.27';
