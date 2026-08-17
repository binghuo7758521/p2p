/**
 * 无限大盘 — 信令服务器
 * 
 * 功能：
 * 1. 10位配对码（大写字母+数字），设备配对
 * 2. WebRTC SDP/ICE 信令转发
 * 3. 托管前端静态文件
 * 4. 激活码激活：电脑端生成激活码（管理员码/普通码），手机端凭码激活
 *    并连接电脑；服务器仅作激活码查询与配对转发，不存任何用户信息
 * 5. 后台管理 API：运行状态 + 电脑端列表
 * 
 * 环境变量（占位配置）：
 *   OSS_BASE_URL               升级包对象存储域名（如 https://xxx.oss-cn-hangzhou.aliyuncs.com，
 *                              配置后 /downloads 302 重定向到 OSS，升级包不占 ECS 带宽）
 * 
 * 启动: node server.js
 * 端口: 3000
 * 后台: http://<服务器>/admin  (默认 admin / admin123)
 */

import express from 'express';
import { createServer } from 'http';
import { Server } from 'socket.io';
import { randomBytes, scryptSync, timingSafeEqual, createHmac, createHash } from 'crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const app = express();
app.use(express.json({ limit: '1mb' }));

// ── HTTP 请求日志（记录方法/路径/状态码/耗时，便于测试排障） ──
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    log(`[HTTP] ${req.method} ${req.originalUrl.split('?')[0]} => ${res.statusCode} ${Date.now() - start}ms`);
  });
  next();
});
const server = createServer(app);
const io = new Server(server, {
  cors: { origin: '*' },
  pingInterval: 10000,
  pingTimeout: 5000
});

const PORT = process.env.PORT || 3000;

// ── 版本号（调试时确认是否最新版本）─────────────────────────
// 规则: 手机端 / 电脑端 / 服务器端 三端版本互相独立（vX.Y）
// - 只要某端代码有修改，该端版本号 +0.1（v1.0 → v1.1 → v1.2 ...）
// - 本文件同时记录三端最新版本，便于 /version 统一核对
const SERVER_VERSION = '2.13';  // 服务器端版本
const DESKTOP_VERSION = '6.18';  // 电脑端版本
const ANDROID_VERSION = '5.25'; // 手机端版本
// 手机端最低可用版本（v2.7+ 强制升级）：低于此版本的手机端一律拒绝
// 激活与连接（update-check 返回 force；激活/信令返回 APP_VERSION_REQUIRED），
// 必须升级到最新版才能正常使用
const MIN_ANDROID_VERSION = '5.6';

// 版本查询接口：调试时确认各端是否最新
app.get('/version', (req, res) => {
  res.json({
    server: SERVER_VERSION,
    desktop: DESKTOP_VERSION,
    android: ANDROID_VERSION
  });
});

// ── 手机端日志上传 ──────────────────────────────────────────────
// 手机端一键上传 app.log 到服务器 logs/ 目录，便于远程排查传输问题
// 请求体为日志纯文本（text/plain），query 携带 deviceId/version
const LOGS_DIR = join(__dirname, 'logs');
app.post('/log-upload', express.text({ limit: '3mb', type: 'text/plain' }), (req, res) => {
  const clean = (s, allowed) => String(s || '').replace(new RegExp(`[^${allowed}]`, 'g'), '');
  const deviceId = clean(req.query.deviceId, '\\w-');
  const version = clean(req.query.version, '\\w.');
  const ts = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
  const name = `${deviceId || 'unknown'}_${version || 'x'}_${ts}.log`;
  const bodyText = typeof req.body === 'string' ? req.body : ''; // 仅接受纯文本日志
  try {
    if (!existsSync(LOGS_DIR)) mkdirSync(LOGS_DIR, { recursive: true });
    writeFileSync(join(LOGS_DIR, name), bodyText);
    log(`[LOG] 收到日志上传: ${name} (${bodyText.length} 字符)`);
    res.json({ ok: true, logId: name });
  } catch (e) {
    log(`[LOG] 日志保存失败: ${e}`);
    res.status(500).json({ ok: false, error: String(e) });
  }
});

// ── 升级检查 ─────────────────────────────────────────────────
// 发布新版本时，将升级包放到 downloads 目录：
//   downloads/p2p_desktop.zip   电脑端升级包（覆盖解压 Release 目录）
//   downloads/app-release.apk   手机端升级包（直接安装）
// 可选：配置 OSS_BASE_URL（阿里云 OSS 等对象存储域名）后，
// /downloads 302 重定向到对象存储直链，升级包不再占用 ECS 公网带宽
// 注意：OSS 默认公网域名禁止匿名下载 .apk 后缀对象（ApkDownloadForbidden），
// 故 APK 在 OSS 中以无后缀对象名存储（上传时 Content-Disposition 还原文件名）
const DOWNLOADS_DIR = join(__dirname, 'downloads');
const OSS_BASE_URL = (process.env.OSS_BASE_URL || '').replace(/\/+$/, '');
// 下载文件名 → OSS 对象名映射（规避 APK 下载限制）
const OSS_OBJECT_MAP = { 'app-release.apk': 'app-release' };

// 升级包 MD5 缓存（客户端完整性校验；按文件大小变化失效）
// 发布时需同时将升级包上传到 downloads 目录，否则返回 null（客户端拒绝静默升级）
let pkgMd5Cache = { file: '', size: -1, md5: '' };
function packageMd5(file) {
  const p = join(DOWNLOADS_DIR, file);
  if (!existsSync(p)) return null;
  const size = statSync(p).size;
  if (pkgMd5Cache.file === p && pkgMd5Cache.size === size) return pkgMd5Cache.md5;
  const h = createHash('md5');
  h.update(readFileSync(p));
  const md5 = h.digest('hex');
  pkgMd5Cache = { file: p, size, md5 };
  return md5;
}

app.use('/downloads', (req, res, next) => {
  if (!OSS_BASE_URL) return next(); // 未配置 OSS：交给本地静态目录
  const file = decodeURIComponent(req.path.replace(/^\//, ''));
  if (!file || file.includes('..')) return res.status(404).end();
  const object = OSS_OBJECT_MAP[file] || file;
  res.redirect(302, OSS_BASE_URL + '/' + encodeURIComponent(object));
});
// 未配置 OSS 时回退本地静态目录（放在路由之后，仅在未配置时注册）
if (!OSS_BASE_URL) {
  app.use('/downloads', express.static(DOWNLOADS_DIR));
}

// 手动下载 APK（v5.7+）：旧版手机端（≤v5.6）自动升级安装链路缺陷无法拉起安装器时，
// 用手机浏览器打开 /manual/apk 直接下载带 .apk 后缀的安装包后手动安装。
// 不走 OSS 直链：OSS 公网 endpoint 禁止分发 APK（ApkDownloadForbidden），
// 且无后缀对象下载后无法被系统识别为安装包。低频路径，占用 ECS 带宽可接受。
app.get('/manual/apk', (req, res) => {
  const file = join(DOWNLOADS_DIR, 'app-release.apk');
  if (!existsSync(file)) return res.status(404).send('升级包不存在');
  res.setHeader('Content-Type', 'application/vnd.android.package-archive');
  res.setHeader('Content-Disposition', 'attachment; filename="app-release.apk"');
  res.sendFile(file);
});

// 版本号转数值（v1.5 → 105），用于大小比较；
// 分段解析避免 parseFloat 把 5.10 解析成 5.1（次版本号 ≥10 时误判为旧版）
function verNum(v) {
  const s = String(v).split('.');
  const major = parseInt(s[0] || '0', 10) || 0;
  const minor = parseInt(s[1] || '0', 10) || 0;
  return major * 100 + minor;
}

// 升级包是否存在：对象存储模式用 HEAD 探测直链，本地模式查文件
async function upgradeFileExists(file) {
  if (OSS_BASE_URL) {
    const object = OSS_OBJECT_MAP[file] || file;
    try {
      const resp = await fetch(`${OSS_BASE_URL}/${object}`, { method: 'HEAD' });
      return resp.ok;
    } catch (e) {
      log(`[升级检查] OSS 探测失败: ${file} ${e}`);
      return false;
    }
  }
  return existsSync(join(DOWNLOADS_DIR, file));
}

// 升级检查：/update-check?platform=desktop|android&version=x.y
// 返回最新版本、是否需要升级、下载地址、更新说明
app.get('/update-check', async (req, res) => {
  const platform = req.query.platform === 'android' ? 'android' : 'desktop';
  const current = String(req.query.version || '');
  const latest = platform === 'android' ? ANDROID_VERSION : DESKTOP_VERSION;
  const file = platform === 'android' ? 'app-release.apk' : 'p2p_desktop.zip';
  const hasFile = await upgradeFileExists(file);
  const needUpdate = hasFile && verNum(latest) > verNum(current);
  // v2.7+ 强制升级：手机端版本低于最低可用版本时标记强制更新
  const force = platform === 'android' && verNum(current) > 0 &&
      verNum(current) < verNum(MIN_ANDROID_VERSION);
  res.json({
    platform,
    current,
    latest,
    needUpdate: needUpdate || force,
    force,
    url: hasFile ? `/downloads/${file}` : null,
    // 手机端升级提示附带安装引导：v5.0 及以下老版本无安装权限引导，
    // 需用户先在系统设置手动开启“安装未知应用”（Android 8+ 硬前提）
    notes: hasFile
        ? (platform === 'android'
            ? `升级到 v${latest}；若自动安装无反应（旧版安装链路缺陷），请用手机浏览器打开 http://182.92.157.93:3000/manual/apk 下载后点击安装`
            : `升级到 v${latest}（服务器已就绪）`)
        : '',
    // 升级包 MD5：客户端下载后完整性校验（无 MD5 时客户端回退手动下载）
    md5: hasFile ? packageMd5(file) : null
  });
  if (platform === 'android') {
    log(`[升级检查] 手机端 v${current} → ${needUpdate ? '有新版 v' + latest : '已最新'}`);
  } else {
    log(`[升级检查] 电脑端 v${current} → ${needUpdate ? '有新版 v' + latest : '已最新'}`);
  }
});

// ── 会话存储 ─────────────────────────────────────────────────
const sessions = new Map();
const PAIR_CODE_FILE = join(process.cwd(), '.pair-code');

// 日志时间戳
function ts() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
const log = (...args) => console.log(ts(), ...args);
const logErr = (...args) => console.error(ts(), ...args);

// 配对码字符集：去掉易混淆的 0/O、1/I
const PAIR_CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const PAIR_CODE_LENGTH = 10;

/** 纯生成配对码（不落盘）：设备码分配 / 全局码共用 */
function randomPairCode() {
  const bytes = randomBytes(PAIR_CODE_LENGTH);
  let code = '';
  for (let i = 0; i < PAIR_CODE_LENGTH; i++) {
    code += PAIR_CODE_CHARS[bytes[i] % PAIR_CODE_CHARS.length];
  }
  return code;
}

function generatePairCode() {
  // 生成新的配对码并持久化
  const code = randomPairCode();
  writeFileSync(PAIR_CODE_FILE, code, 'utf-8');
  console.log(`[配对码] 生成新配对码: ${code} (已保存)`);
  return code;
}

function getOrCreatePairCode() {
  // 尝试读取已保存的配对码
  if (existsSync(PAIR_CODE_FILE)) {
    const saved = readFileSync(PAIR_CODE_FILE, 'utf-8').trim();
    if (new RegExp(`^[A-Z0-9]{${PAIR_CODE_LENGTH}}$`).test(saved)) {
      console.log(`[配对码] 使用已保存的配对码: ${saved}`);
      return saved;
    }
  }
  // 生成新的并保存
  return generatePairCode();
}

// ── 按设备分配配对码（v2.2+）───────────────────────────────────
// 背景：v2.1 及之前所有电脑端共用服务器全局一个配对码（.pair-code），
// 多台电脑安装后码相同且互相抢占。v2.2 起电脑端上报本机硬件 ID，
// 服务器按 deviceId 维护映射：同一台电脑配对码稳定，不同电脑互不相同。
const HOST_CODES_FILE = join(process.cwd(), 'host-codes.json');

function loadHostCodes() {
  try {
    if (existsSync(HOST_CODES_FILE)) {
      const codes = JSON.parse(readFileSync(HOST_CODES_FILE, 'utf-8'));
      if (codes && typeof codes === 'object') return codes;
    }
  } catch (e) {
    console.error(`[配对码] 读取 ${HOST_CODES_FILE} 失败: ${e.message}`);
  }
  return {};
}

/** 按设备取/分配配对码：同一 deviceId 返回同一码；新设备生成不重复的新码 */
function getOrCreateHostCode(deviceId) {
  const codes = loadHostCodes();
  if (deviceId && codes[deviceId]) return codes[deviceId];
  let code;
  do {
    code = randomPairCode();
  } while (Object.values(codes).includes(code) ||
      (existsSync(PAIR_CODE_FILE) && code === readFileSync(PAIR_CODE_FILE, 'utf-8').trim()));
  if (deviceId) {
    codes[deviceId] = code;
    saveJson(HOST_CODES_FILE, codes);
    console.log(`[配对码] 新设备 ${deviceId} → ${code}`);
  }
  return code;
}

/** 重新生成某设备的配对码（pair:reset）：旧码立即失效，映射持久化 */
function resetHostCode(deviceId) {
  const codes = loadHostCodes();
  let code;
  do {
    code = randomPairCode();
  } while (Object.values(codes).includes(code) ||
      (existsSync(PAIR_CODE_FILE) && code === readFileSync(PAIR_CODE_FILE, 'utf-8').trim()));
  codes[deviceId] = code;
  saveJson(HOST_CODES_FILE, codes);
  console.log(`[配对码] 设备 ${deviceId} 重新生成 → ${code}`);
  return code;
}

/** 配对码是否有效：全局码（旧电脑端）或任一设备的专属码 */
function isValidPairCode(code) {
  if (!code) return false;
  if (existsSync(PAIR_CODE_FILE) && readFileSync(PAIR_CODE_FILE, 'utf-8').trim() === code) {
    return true;
  }
  return Object.values(loadHostCodes()).includes(code);
}

/** 读取当前有效配对码（只读，不生成）：用于区分“电脑端离线”与“配对码已变更” */
function getCurrentPairCode() {
  if (existsSync(PAIR_CODE_FILE)) {
    const saved = readFileSync(PAIR_CODE_FILE, 'utf-8').trim();
    if (new RegExp(`^[A-Z0-9]{${PAIR_CODE_LENGTH}}$`).test(saved)) {
      return saved;
    }
  }
  return null;
}

// ── 共享注册表（v2.4+）────────────────────────────────────
// 电脑端创建/删除/修改共享时全量同步到服务器，手机端激活后按设备
// 拉取“共享给我的”列表，并通过 client:join-by-share 免配对码连接电脑端。
// shareRegistry: { token: { token, deviceId, pairCode, hostName, name,
//   folder, perms[], targetDeviceId|null, createdAt, updatedAt } }
const SHARES_FILE = join(process.cwd(), 'shares.json');
let shareRegistry = loadJson(SHARES_FILE, {});
if (!shareRegistry || typeof shareRegistry !== 'object') shareRegistry = {};

function saveShares() {
  try {
    saveJson(SHARES_FILE, shareRegistry);
  } catch (e) {
    console.error(`[共享] 保存 ${SHARES_FILE} 失败: ${e.message}`);
  }
}

// ── 扫码加入绑定（v2.8+）────────────────────────────────────
// 手机端通过 client:join-by-share 扫码加入公开共享时记录 deviceId→token 绑定，
// 使该共享持久化出现在“共享给我的”列表中（免重复扫码）；
// 独立存储：电脑端 /api/shares/sync 全量覆盖不会冲掉绑定关系。
// 绑定结构: { deviceId: { token: joinedAt } }
const JOIN_FILE = join(process.cwd(), 'join-relations.json');
let joinRelations = loadJson(JOIN_FILE, {});
if (!joinRelations || typeof joinRelations !== 'object') joinRelations = {};

function saveJoinRelations() {
  try {
    saveJson(JOIN_FILE, joinRelations);
  } catch (e) {
    console.error(`[共享] 保存 ${JOIN_FILE} 失败: ${e.message}`);
  }
}

// 电脑端 HTTP 同步认证：host:register 时注册的 hostToken（防伪造共享上报）
const HOST_TOKENS_FILE = join(process.cwd(), 'host-tokens.json');
function loadHostTokens() {
  return loadJson(HOST_TOKENS_FILE, {});
}
function saveHostTokens(ht) {
  try {
    saveJson(HOST_TOKENS_FILE, ht);
  } catch (e) {
    console.error(`[共享] 保存 ${HOST_TOKENS_FILE} 失败: ${e.message}`);
  }
}

// 电脑端全量同步共享（幂等：以电脑端上报为准，覆盖该设备全部条目）
function syncHostShares(deviceId, shares) {
  if (!deviceId) return { ok: false, error: '缺少设备标识' };
  const codes = loadHostCodes();
  const pairCode = codes[deviceId] || null;
  const valid = Array.isArray(shares) ? shares : [];
  // 先移除该设备旧条目，再写入新条目（删除/修改后自然收敛）
  for (const key of Object.keys(shareRegistry)) {
    if (shareRegistry[key].deviceId === deviceId) {
      delete shareRegistry[key];
    }
  }
  const now = Date.now();
  for (const s of valid) {
    const token = String(s.token || '');
    if (!token) continue;
    shareRegistry[token] = {
      token,
      deviceId,
      pairCode,
      hostName: String(s.hostName || '电脑').slice(0, 50),
      name: String(s.name || '共享文件夹').slice(0, 100),
      folder: String(s.folder || '').slice(0, 500),
      perms: Array.isArray(s.perms)
          ? s.perms.filter((p) => ['download', 'upload', 'delete'].includes(p))
          : [],
      targetDeviceId: s.targetDeviceId ? String(s.targetDeviceId).slice(0, 64) : null,
      createdAt: Number(s.createdAt) || now,
      updatedAt: now,
    };
  }
  saveShares();
  log(`[共享] 电脑端同步: ${deviceId} 共 ${valid.length} 条`);
  return { ok: true, count: valid.length };
}

// ── 用户数据存储 ─────────────────────────────────────────────
const USERS_FILE = join(process.cwd(), 'users.json');
const TOKENS_FILE = join(process.cwd(), 'tokens.json');

// ── U盘授权（加密狗）存储 ───────────────────────────────────
const LICENSES_FILE = join(process.cwd(), 'licenses.json');
// 未授权时电脑端展示的购买方式（后台改不了，直接改这里后重启生效）
const BUY_CONTACT = {
  title: '如需购买授权，请联系：',
  wechat: '客服微信：your-wechat-id',
  phone: '客服电话：400-000-0000',
};

function loadLicenses() {
  try {
    if (existsSync(LICENSES_FILE)) {
      const data = JSON.parse(readFileSync(LICENSES_FILE, 'utf-8'));
      if (data && Array.isArray(data.usbIds)) return data;
    }
  } catch (e) {
    console.error(`[授权] 读取 ${LICENSES_FILE} 失败: ${e.message}`);
  }
  return { usbIds: [] };
}
const licenses = loadLicenses();

// U盘ID 格式：XXXX-XXXX（16 进制卷序列号）
function isUsbIdValid(id) {
  return /^[0-9A-F]{4}-[0-9A-F]{4}$/.test(id);
}

function loadJson(file, fallback) {
  try {
    if (existsSync(file)) return JSON.parse(readFileSync(file, 'utf-8'));
  } catch (e) {
    console.error(`[存储] 读取 ${file} 失败: ${e.message}`);
  }
  return fallback;
}

function saveJson(file, data) {
  writeFileSync(file, JSON.stringify(data, null, 2), 'utf-8');
}

// 管理后台库: { admin: { username, salt, hash, createdAt } }
// v2.6+ 去手机号后不再存储任何用户，users 数组仅兼容历史文件保留
const db = loadJson(USERS_FILE, { users: [], admin: null });
if (!Array.isArray(db.users)) db.users = [];
saveJson(USERS_FILE, db); // 确保文件存在

// 密码哈希（scrypt + 随机盐）
function hashPassword(password) {
  const salt = randomBytes(16).toString('hex');
  const hash = scryptSync(password, salt, 64).toString('hex');
  return { salt, hash };
}

function verifyPassword(password, salt, hash) {
  try {
    const h = scryptSync(password, salt, 64);
    const expected = Buffer.from(hash, 'hex');
    return h.length === expected.length && timingSafeEqual(h, expected);
  } catch {
    return false;
  }
}

// 初始管理员：admin / admin123（首次启动自动创建）
function ensureAdmin() {
  if (!db.admin) {
    db.admin = { username: 'admin', ...hashPassword('admin123'), createdAt: Date.now() };
    saveJson(USERS_FILE, db);
    console.log('[管理] 初始管理员已创建: admin / admin123（请尽快登录后台修改）');
  }
}
ensureAdmin();

// ── Token 管理 ───────────────────────────────────────────────
const TOKEN_TTL_MS = 30 * 24 * 3600 * 1000; // 30 天
const tokens = loadJson(TOKENS_FILE, {});

function saveTokens() {
  saveJson(TOKENS_FILE, tokens);
}

function createToken(uid, role) {
  const token = randomBytes(24).toString('hex');
  tokens[token] = { uid, role, createdAt: Date.now() };
  saveTokens();
  return token;
}

function getTokenInfo(req) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const info = tokens[token];
  if (!info) return null;
  if (Date.now() - info.createdAt > TOKEN_TTL_MS) {
    delete tokens[token];
    saveTokens();
    return null;
  }
  return info;
}

// 定时清理过期 token
setInterval(() => {
  let changed = false;
  const now = Date.now();
  for (const [t, info] of Object.entries(tokens)) {
    if (now - info.createdAt > TOKEN_TTL_MS) {
      delete tokens[t];
      changed = true;
    }
  }
  if (changed) saveTokens();
}, 3600 * 1000);

// ── 激活码体系（v2.6+，去手机号） ──────────────────────────
// 电脑端本地生成激活码（管理员码/普通码）并同步到服务器；手机端输入
// 激活码换取配对码+设备令牌，凭设备令牌拉取“共享给我的”列表。
// 服务器只存临时凭证（激活码/设备令牌），不存任何用户个人信息。
const ACT_CODE_TTL_MS = 24 * 3600 * 1000; // 激活码 24 小时有效
const actCodes = new Map(); // code -> { pairCode, type, createdAt }
const usedCodes = new Map(); // code -> usedAt（防重放，保留 24h）
const ACT_DEVICES_FILE = join(process.cwd(), 'act-devices.json');
let actDevices = loadJson(ACT_DEVICES_FILE, {}); // deviceId -> { token, createdAt }
if (!actDevices || typeof actDevices !== 'object') actDevices = {};

function saveActDevices() {
  try {
    saveJson(ACT_DEVICES_FILE, actDevices);
  } catch (e) {
    console.error(`[激活] 保存 ${ACT_DEVICES_FILE} 失败: ${e.message}`);
  }
}

/** 电脑端上报未用激活码列表（host:sync-codes，幂等覆盖该设备的码） */
function syncActivationCodes(deviceId, pairCode, codes) {
  if (!deviceId || !pairCode) return;
  // 先清掉该设备旧码（防止电脑端重启后旧码残留）
  for (const [c, info] of [...actCodes]) {
    if (info.pairCode === pairCode) actCodes.delete(c);
  }
  const now = Date.now();
  for (const c of Array.isArray(codes) ? codes : []) {
    const code = String(c?.code || '');
    // v6.14+ 身份二态化：仅管理员码一种类型（不再接受普通码）
    const type = 'admin';
    if (!code) continue;
    if (usedCodes.has(code)) continue; // 已用过的码不再注册
    actCodes.set(code, { pairCode, type, createdAt: now });
  }
  log(`[激活] 电脑端同步激活码: ${deviceId} 共 ${actCodes.size} 个有效码`);
}

// 定期清理过期激活码与防重放记录
setInterval(() => {
  const now = Date.now();
  for (const [c, info] of [...actCodes]) {
    if (now - info.createdAt > ACT_CODE_TTL_MS) actCodes.delete(c);
  }
  for (const [c, t] of [...usedCodes]) {
    if (now - t > ACT_CODE_TTL_MS) usedCodes.delete(c);
  }
}, 3600 * 1000);

// ── 认证中间件（仅后台管理员） ───────────────────────────────
// 后台管理员认证
function requireAdmin(req, res, next) {
  const info = getTokenInfo(req);
  if (!info) return res.status(401).json({ ok: false, error: '未登录或登录已过期' });
  if (info.role !== 'admin') return res.status(403).json({ ok: false, error: '无管理员权限' });
  next();
}

// ── 手机端激活 API（v2.6+，去手机号） ─────────────────────────────
// 手机端凭电脑端发放的管理员激活码换取配对码 + 设备令牌：
// - 激活码一次性、24 小时有效，由电脑端生成/撤销，服务器只做查询与标记
// - 设备令牌（deviceToken）用于 /api/shares/mine 等接口鉴权
// - 服务器不存用户个人信息，仅存临时凭证（act-devices.json）
app.post('/api/activate', (req, res) => {
  const version = String(req.body?.version || '');
  // v2.7+ 强制升级：旧版手机端（低于最低可用版本）拒绝激活
  if (!version || verNum(version) < verNum(MIN_ANDROID_VERSION)) {
    log(`[激活] 拒绝: 旧版手机端 v${version || '未知'}（最低 v${MIN_ANDROID_VERSION}）`);
    return res.json({ ok: false, error: 'APP_VERSION_REQUIRED', latest: ANDROID_VERSION });
  }
  const code = String(req.body?.code || '').trim().toUpperCase();
  const deviceId = String(req.body?.deviceId || '').trim();
  const now = Date.now();
  if (!/^[A-Z0-9]{6,12}$/.test(code)) {
    log(`[激活] 拒绝: 激活码格式不正确 ${code}`);
    return res.json({ ok: false, error: '激活码格式不正确' });
  }
  if (!deviceId) {
    log(`[激活] 拒绝: 缺少设备标识`);
    return res.json({ ok: false, error: '设备标识无效' });
  }
  const info = actCodes.get(code);
  // 已使用检查前置：避免用过即删的码被误报为“无效或已过期”
  if (usedCodes.has(code)) {
    log(`[激活] 失败: 激活码已被使用 ${code}`);
    return res.json({ ok: false, error: '激活码已被使用' });
  }
  if (!info) {
    log(`[激活] 失败: 激活码无效或已过期 ${code}`);
    return res.json({ ok: false, error: '激活码无效或已过期' });
  }
  // 设备重新激活：撤销旧令牌（原设备需重新激活才能拉取共享）
  if (actDevices[deviceId]) {
    log(`[激活] 设备重新激活，撤销旧令牌: ${deviceId}`);
    delete actDevices[deviceId];
  }
  usedCodes.set(code, now);
  actCodes.delete(code);
  const deviceToken = createHmac('sha256', 'act-device:' + info.pairCode)
      .update(deviceId + ':' + now)
      .digest('hex')
      .slice(0, 32);
  actDevices[deviceId] = {
    token: deviceToken,
    pairCode: info.pairCode,
    type: info.type,
    createdAt: now,
  };
  saveActDevices();
  log(`[激活] 成功: ${deviceId} type=${info.type} → 配对码 ${info.pairCode}`);
  // 通知电脑端该码已被兑换（管理页标记已用）
  const sess = sessions.get(info.pairCode);
  if (sess?.hostSocketId) {
    io.to(sess.hostSocketId).emit('host:code-used', { code });
  }
  res.json({ ok: true, pairCode: info.pairCode, type: info.type, deviceToken });
});

// 激活码状态查询（v2.10+）：扫码/粘贴/激活前即时校验，二次扫描提示失效
// - 8 位随机码本身即凭证，查询不增加攻击面（无法凭查询结果使用或伪造码）
// - 已使用（usedCodes 命中）→ valid:false reason:'used'
// - 有效（actCodes 命中）→ valid:true
// - 不存在/已撤销/已过期 → valid:false reason:'invalid'
app.get('/api/activate-status', (req, res) => {
  const code = String(req.query.code || '').trim().toUpperCase();
  if (!/^[A-Z0-9]{6,12}$/.test(code)) {
    return res.json({ ok: false, error: '激活码格式不正确' });
  }
  if (usedCodes.has(code)) {
    return res.json({ ok: true, valid: false, reason: 'used' });
  }
  const info = actCodes.get(code);
  if (info) {
    return res.json({ ok: true, valid: true });
  }
  return res.json({ ok: true, valid: false, reason: 'invalid' });
});









// ── 共享同步与查询 API（v2.4+）───────────────────────────────
// 电脑端全量同步共享（创建/删除/改权限/启动时调用，幂等覆盖）
app.post('/api/shares/sync', (req, res) => {
  const deviceId = String(req.body?.deviceId || '');
  const hostToken = String(req.body?.hostToken || '');
  const tokens = loadHostTokens();
  if (!deviceId || !hostToken || tokens[deviceId] !== hostToken) {
    return res.status(403).json({ ok: false, error: '主机令牌无效' });
  }
  const result = syncHostShares(deviceId, req.body?.shares);
  res.json(result);
});

// 手机端：凭设备令牌拉取“共享给我的”文件夹列表（按激活设备匹配）
// 返回在线状态（电脑端在线可立即连接），不暴露共享目录绝对路径
app.get('/api/shares/mine', (req, res) => {
  const deviceId = String(req.query.deviceId || '').trim();
  const deviceToken = String(req.query.deviceToken || '').trim();
  const rec = deviceId ? actDevices[deviceId] : null;
  // v2.11+：共享访客（扫码共享码自动激活，type='guest'）凭令牌拉取；
  // 绑定设备（曾凭共享码加入，join-relations 有记录）仅可看自己的绑定共享
  const authed = !!(rec && rec.token === deviceToken);
  const bound = !!deviceId && !!joinRelations[deviceId] &&
      Object.keys(joinRelations[deviceId]).length > 0;
  if (!authed && !bound) {
    log(`[共享] 手机端查询拒绝: 设备令牌无效 ${deviceId}`);
    return res.status(401).json({ ok: false, error: '设备令牌无效，请重新激活' });
  }
  const list = [];
  for (const s of Object.values(shareRegistry)) {
    // v2.8+：定向共享（targetDeviceId 精确匹配，仅令牌有效设备可见）∪ 扫码加入
    // 过的公开共享（join-relations 绑定；扫码即授权，绑定记录天然经过认证）
    const isTarget = authed && s.targetDeviceId && s.targetDeviceId === deviceId;
    const isJoined = !s.targetDeviceId && !!joinRelations[deviceId] &&
        !!joinRelations[deviceId][s.token];
    if (!isTarget && !isJoined) continue;
    const online = !!(s.pairCode &&
        sessions.get(s.pairCode)?.hostSocketId &&
        io.sockets.sockets.has(sessions.get(s.pairCode).hostSocketId));
    list.push({
      token: s.token,
      hostName: s.hostName || '电脑',
      name: s.name || '共享文件夹',
      perms: s.perms || [],
      online,
      updatedAt: s.updatedAt || null,
    });
  }
  list.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
  log(`[共享] 手机端查询: ${deviceId} 共 ${list.length} 条`);
  res.json({ ok: true, shares: list });
});

// 手机端上报扫码加入绑定（v2.9+）：已连接电脑扫码附加共享（attachShare）时
// 服务器无感知，手机端主动上报 token 使共享持久化出现在“共享给我的”列表；
// 校验：激活设备令牌 + 共享有效（与 join-by-share 同口径）
app.post('/api/shares/join', (req, res) => {
  const { deviceId, deviceToken, token } = req.body || {};
  const share = token ? shareRegistry[token] : null;
  if (!share || !share.pairCode) {
    log(`[共享] 绑定失败: 共享不存在或已失效 token=${token}`);
    return res.json({ ok: false, error: '共享不存在或已失效' });
  }
  const rec = deviceId ? actDevices[deviceId] : null;
  if (!rec || rec.token !== deviceToken) {
    log(`[共享] 绑定失败: 设备令牌无效 ${deviceId}`);
    return res.status(401).json({ ok: false, error: '设备令牌无效，请重新激活' });
  }
  joinRelations[deviceId] = joinRelations[deviceId] || {};
  if (!joinRelations[deviceId][token]) {
    log(`[共享] 记录扫码加入(attach): ${deviceId} → ${share.name}`);
  }
  joinRelations[deviceId][token] = Date.now();
  saveJoinRelations();
  res.json({ ok: true });
});

// ── 管理 API ─────────────────────────────────────────────────
// 管理员登录
app.post('/api/admin/login', (req, res) => {
  const username = String(req.body?.username || '').trim();
  const password = String(req.body?.password || '');
  if (!db.admin || username !== db.admin.username || !verifyPassword(password, db.admin.salt, db.admin.hash)) {
    log(`[管理] 登录失败: ${username}`);
    return res.json({ ok: false, error: '用户名或密码错误' });
  }
  const token = createToken('admin', 'admin');
  console.log(`[管理] 管理员登录成功`);
  res.json({ ok: true, token });
});

// 用户管理已移至电脑端本地（v2.6+ 去手机号后服务器不存用户，无此接口）

// 系统运行状态
app.get('/api/admin/stats', requireAdmin, (req, res) => {
  res.json({
    ok: true,
    stats: {
      status: 'ok',
      uptime: Math.floor(process.uptime()),
      serverTime: Date.now(),
      sessions: sessions.size,
      users: db.users.length,
      activeUsers: db.users.filter((u) => u.status === 'active').length,
      memory: process.memoryUsage().rss,
      nodeVersion: process.version,
    },
  });
});

// 电脑端列表：在线（sessions 中主机 socket 存活）与全部已注册设备（host-codes.json）
app.get('/api/admin/hosts', requireAdmin, (req, res) => {
  const codes = loadHostCodes();
  const offlineCodes = { ...codes };
  const online = [];
  for (const [pairCode, session] of sessions) {
    if (!session?.hostSocketId || !io.sockets.sockets.has(session.hostSocketId)) continue;
    const info = session.hostInfo || {};
    online.push({
      deviceId: info.deviceId || null,
      name: info.name || '电脑',
      version: info.version || null,
      pairCode,
      online: true,
      clientCount: session.clients ? session.clients.size : 0,
      registeredAt: info.registeredAt || session.createdAt || null,
    });
    if (info.deviceId) delete offlineCodes[info.deviceId];
  }
  // 已注册但当前不在线的设备（host-codes.json 映射），在线优先排序
  const offline = Object.entries(offlineCodes).map(([deviceId, pairCode]) => ({
    deviceId,
    name: null,
    version: null,
    pairCode,
    online: false,
    clientCount: 0,
    registeredAt: null,
  }));
  const hosts = [...online, ...offline];
  log(`[管理] 电脑端列表: 在线 ${online.length} 台 / 已注册 ${hosts.length} 台`);
  res.json({ ok: true, hosts, onlineCount: online.length });
});

// ── U盘授权 API（加密狗白名单） ────────────────────────────
// 电脑端启动验证：任意一个U盘ID在白名单中即授权通过
app.post('/api/usb/verify', (req, res) => {
  const ids = Array.isArray(req.body?.usbIds)
      ? req.body.usbIds.map((s) => String(s).trim().toUpperCase()).filter(Boolean)
      : [];
  const licensed = ids.some((id) => licenses.usbIds.some((x) => x.id === id));
  if (licensed) return res.json({ ok: true, licensed: true });
  res.json({ ok: true, licensed: false, buyInfo: BUY_CONTACT });
});

// 管理：授权列表
app.get('/api/admin/usb/list', requireAdmin, (req, res) => {
  const list = [...licenses.usbIds].sort((a, b) => b.createdAt - a.createdAt);
  res.json({
    ok: true,
    count: list.length,
    list: list.map((x) => ({
      id: x.id,
      note: x.note || '',
      createdAt: x.createdAt,
    })),
  });
});

// 管理：单个添加
app.post('/api/admin/usb/add', requireAdmin, (req, res) => {
  const id = String(req.body?.id || '').trim().toUpperCase();
  const note = String(req.body?.note || '').trim();
  if (!isUsbIdValid(id)) {
    return res.json({ ok: false, error: 'ID 格式应为 XXXX-XXXX（例如 1A2B-3C4D）' });
  }
  if (licenses.usbIds.some((x) => x.id === id)) {
    return res.json({ ok: false, error: `ID ${id} 已存在` });
  }
  licenses.usbIds.push({ id, note, createdAt: Date.now() });
  saveJson(LICENSES_FILE, licenses);
  console.log(`[授权] 添加U盘ID: ${id} ${note ? `(${note})` : ''}`);
  res.json({ ok: true });
});

// 管理：批量添加（多行/逗号分隔文本，自动去重、忽略空行）
app.post('/api/admin/usb/batch', requireAdmin, (req, res) => {
  const text = String(req.body?.text || '');
  const rows = text
      .split(/[\r\n,;，；]+/)
      .map((s) => s.trim().toUpperCase())
      .filter(Boolean);
  let added = 0;
  let skipped = 0;
  const invalid = [];
  for (const row of rows) {
    if (!isUsbIdValid(row)) {
      invalid.push(row);
      continue;
    }
    if (licenses.usbIds.some((x) => x.id === row)) {
      skipped++;
      continue;
    }
    licenses.usbIds.push({ id: row, note: '', createdAt: Date.now() });
    added++;
  }
  saveJson(LICENSES_FILE, licenses);
  console.log(`[授权] 批量添加: 成功 ${added} / 跳过重复 ${skipped} / 无效 ${invalid.length}`);
  res.json({ ok: true, added, skipped, invalid });
});

// 管理：删除
app.delete('/api/admin/usb/:id', requireAdmin, (req, res) => {
  const id = String(req.params.id || '').trim().toUpperCase();
  const before = licenses.usbIds.length;
  licenses.usbIds = licenses.usbIds.filter((x) => x.id !== id);
  if (licenses.usbIds.length === before) {
    return res.json({ ok: false, error: 'ID 不存在' });
  }
  saveJson(LICENSES_FILE, licenses);
  console.log(`[授权] 删除U盘ID: ${id}`);
  res.json({ ok: true });
});

// ── 静态文件 ─────────────────────────────────────────────────
// 仅托管页面文件，避免暴露 server.js / package.json / .pair-code / users.json 等
app.get('/', (req, res) => {
  res.sendFile(join(__dirname, 'index.html'));
});

app.get('/admin', (req, res) => {
  res.sendFile(join(__dirname, 'admin.html'));
});

app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', sessions: sessions.size, uptime: process.uptime() });
});

// ── TURN 中继凭证（coturn static-auth-secret 模式，1 小时时效） ──────
// 仅当服务器配置了 TURN_SECRET 时下发，客户端 ICE 据此接入中继
const TURN_SECRET = process.env.TURN_SECRET || '';
const TURN_SERVER_URL = process.env.TURN_SERVER_URL || 'turn:182.92.157.93:3478';
function issueTurnCredential() {
  if (!TURN_SECRET) return null;
  const expiry = Math.floor(Date.now() / 1000) + 3600;
  const username = `${expiry}:p2p`;
  const credential = createHmac('sha1', TURN_SECRET)
    .update(username)
    .digest('base64');
  log(`[TURN] 签发中继凭证 username=${username}`);
  return {
    urls: [TURN_SERVER_URL, `${TURN_SERVER_URL}?transport=tcp`],
    username,
    credential,
  };
}

// ── Socket.IO 信令 ───────────────────────────────────────────
io.on('connection', (socket) => {
  log(`[连接] ${socket.id} 新连接`);

  // 电脑端注册为主机（version：电脑端上报的版本号，记录于配对日志）
  // v2.6+：activationCodes 为该电脑当前未用激活码列表（管理员码/普通码），
  // 服务器据此响应手机端 /api/activate 换取配对码与设备令牌
  // 空消息防御：恶意/异常客户端发空 body 会触发解构崩溃，必须先判空
  socket.on('host:register', (msg) => {
    const { deviceName, desktop, version, deviceId, hostToken, activationCodes } = msg || {};
    // v2.4+：绑定主机令牌（电脑端本地生成并持久化，供共享同步接口认证）
    if (deviceId && hostToken) {
      const ht = loadHostTokens();
      if (ht[deviceId] !== hostToken) {
        ht[deviceId] = hostToken;
        saveHostTokens(ht);
        log(`[注册] 绑定主机令牌: deviceId=${deviceId}`);
      }
    }
    // v2.2+：按本机硬件 ID 分配设备专属配对码（同一台电脑重连后码不变，
    // 不同电脑互不相同）；旧版电脑端（未上报 deviceId）回退到全局码
    const pairCode = deviceId ? getOrCreateHostCode(deviceId) : getOrCreatePairCode();
    socket.deviceId = deviceId || null;
    const existing = sessions.get(pairCode);
    // 旧主机 socket 仍存活时才视为“新电脑抢占”，通知手机端断开；
    // 电脑端 socket 闪断重连（旧 socket 已死）：保留手机端会话与配对信息，
    // 不通知断开——P2P 数据通道不依赖信令服务器，手机端可继续传输
    const oldHostAlive = !!(existing &&
        existing.hostSocketId &&
        existing.hostSocketId !== socket.id &&
        io.sockets.sockets.has(existing.hostSocketId));
    if (oldHostAlive && existing.clients) {
      for (const cid of existing.clients.keys()) {
        io.to(cid).emit('peer:disconnected');
      }
    }
    // 多客户端：clients = Map<socketId, {name, deviceId, shareToken}>
    const clients = existing && !oldHostAlive && existing.clients
        ? existing.clients
        : new Map();
    sessions.set(pairCode, {
      hostSocketId: socket.id,
      clients,
      hostInfo: {
        name: deviceName || '电脑',
        id: socket.id,
        desktop: desktop || null,
        version: version || null,
        deviceId: deviceId || null,
        registeredAt: Date.now()
      },
      createdAt: existing?.createdAt ?? Date.now()
    });
    socket.pairCode = pairCode;
    socket.role = 'host';
    // 同步该电脑的未用激活码（生成/撤销后也走 host:sync-codes 增量同步）
    syncActivationCodes(deviceId, pairCode, activationCodes);
    socket.emit('host:registered', { pairCode });
    // 手机端已在等待（注册前 join 成功）：补发 joined 给两端，
    // 电脑端立即发起 offer，手机端确认配对——避免双方互相等待的死锁
    if (clients.size > 0) {
      for (const [cid, info] of [...clients]) {
        if (!io.sockets.sockets.has(cid)) {
          clients.delete(cid);
          continue;
        }
        log(`[补发] 电脑端注册时补发joined: 手机=${cid} 电脑=${socket.id}`);
        socket.emit('host:client-joined', {
          clientInfo: {
            name: info?.name || '手机',
            id: cid,
            deviceId: info?.deviceId || null,
            activationCode: info?.activationCode || null,
            shareToken: info?.shareToken || null
          },
          turn: issueTurnCredential()
        });
        io.to(cid).emit('client:joined', {
          hostInfo: sessions.get(pairCode)?.hostInfo || null,
          turn: issueTurnCredential()
        });
      }
    }
    log(`[注册] ${deviceName || '电脑'}${version ? ' v' + version : ''} → 配对码 ${pairCode} (socket=${socket.id})`);
  });

  // 电脑端同步激活码（v2.6+）：生成/撤销激活码后增量同步，幂等覆盖该设备码表
  // 空消息防御：发空 body 会触发解构崩溃
  socket.on('host:sync-codes', (msg) => {
    const { codes } = msg || {};
    if (socket.role !== 'host' || !socket.pairCode) return;
    syncActivationCodes(socket.deviceId, socket.pairCode, codes);
    socket.emit('host:codes-synced', { ok: true });
  });

  // 电脑端主动离线（v2.5+）：删除会话并通知手机端断开——与意外断线
  // （保留会话、等待自动重连覆盖）不同，主动离线后手机端 join 会立即
  // 收到 host-offline，不会登记等待
  socket.on('host:offline', () => {
    if (socket.role !== 'host' || !socket.pairCode) return;
    const code = socket.pairCode;
    const session = sessions.get(code);
    if (session?.clients) {
      for (const cid of session.clients.keys()) {
        io.to(cid).emit('peer:disconnected');
      }
    }
    sessions.delete(code);
    log(`[离线] 电脑端主动离线: ${socket.id} code=${code}`);
  });

  // 重新生成配对码（仅主机可用）：旧码失效。
  // v2.2+ 只重置本设备自己的码（不广播，避免影响其他电脑端）；
  // 旧版电脑端（无 deviceId）仍走全局码广播逻辑
  socket.on('pair:reset', () => {
    if (socket.role !== 'host' || !socket.pairCode) return;
    const oldCode = socket.pairCode;
    const oldSession = sessions.get(oldCode);
    // 通知旧配对码下已连接的客户端断开
    if (oldSession?.clients) {
      for (const cid of oldSession.clients.keys()) {
        io.to(cid).emit('peer:disconnected');
      }
    }
    sessions.delete(oldCode);
    const newCode = socket.deviceId
        ? resetHostCode(socket.deviceId)
        : generatePairCode();
    sessions.set(newCode, {
      hostSocketId: socket.id,
      clients: new Map(),
      hostInfo: oldSession?.hostInfo || { name: '电脑', id: socket.id },
      createdAt: Date.now()
    });
    socket.pairCode = newCode;
    // 设备专属码：只通知本设备；全局码：广播所有（旧行为）
    if (socket.deviceId) {
      socket.emit('pair:code-changed', { pairCode: newCode });
    } else {
      io.emit('pair:code-changed', { pairCode: newCode });
    }
    console.log(`[配对码] ${socket.deviceId ? '设备 ' + socket.deviceId : '全局'} ${oldCode} → 重新生成 ${newCode}`);
  });

  // 手机端通过配对码加入（支持多客户端：deviceId 设备标识 / shareToken 共享码 /
  // activationCode 激活码，激活码用于电脑端判定该手机是否为管理员）
  // version：手机端上报的版本号，记录于配对日志便于排查版本差异
    // 手机端加入公共流程：配对码（client:join）与共享码（client:join-by-share）
  // 两种入口复用同一路由逻辑（免配对码连接由服务器按共享注册表解析出 pairCode）
  function joinClient(socket, { pairCode, deviceName, deviceId, shareToken, activationCode, version }) {
    // v2.7+ 强制升级：旧版手机端（低于最低可用版本）拒绝连接
    if (!version || verNum(version) < verNum(MIN_ANDROID_VERSION)) {
      log(`[强制升级] 拒绝旧版手机端连接: ${deviceName || '手机'} v${version || '未知'}（最低 v${MIN_ANDROID_VERSION}）`);
      return socket.emit('client:error', { reason: 'APP_VERSION_REQUIRED', latest: ANDROID_VERSION });
    }
    let session = sessions.get(pairCode);
    if (!session || !session.hostSocketId || !io.sockets.sockets.has(session.hostSocketId)) {
      // 会话不存在或主机 socket 已死（电脑端离线/服务器重启后未注册）：
      // 若配对码仍是有效码 → host-offline（手机端自动等待电脑端上线重试）；
      // 否则配对码已失效（全局码被重新生成 / 设备码被重置）→ 需重新扫码
      if (isValidPairCode(pairCode)) {
        // 登记等待中的手机端（即使电脑端离线），电脑端注册时据此补发 joined
        session = session || { hostSocketId: null, clients: new Map(), createdAt: Date.now() };
        if (!session.clients) session.clients = new Map();
        session.clients.set(socket.id, {
          name: deviceName || '手机',
          deviceId: deviceId || null,
          activationCode: activationCode || null,
          shareToken: shareToken || null,
          version: version || null
        });
        sessions.set(pairCode, session);
        log(`[等待] 电脑端离线，登记等待者: ${deviceName}${version ? ' v' + version : ''} socket=${socket.id} code=${pairCode}`);
        return socket.emit('client:error', { reason: 'host-offline' });
      }
      log(`[无效] 配对码无效: ${deviceName} 请求码=${pairCode} 当前码=${getCurrentPairCode() || '无'}`);
      return socket.emit('client:error', { reason: '配对码无效' });
    }
    if (!session.clients) session.clients = new Map();
    // 同一设备断线重连：旧 socket 被新连接替换（通知旧连接断开）
    if (deviceId) {
      for (const [cid, info] of [...session.clients]) {
        if (cid !== socket.id && info?.deviceId === deviceId) {
          io.to(cid).emit('peer:disconnected');
          session.clients.delete(cid);
          log(`[替换] 设备重连替换旧连接: deviceId=${deviceId} 旧=${cid} 新=${socket.id}`);
        }
      }
    }
    session.clients.set(socket.id, {
      name: deviceName || '手机',
      deviceId: deviceId || null,
      activationCode: activationCode || null,
      shareToken: shareToken || null,
      version: version || null
    });
    socket.pairCode = pairCode;
    socket.role = 'client';
    socket.hostSocketId = session.hostSocketId;

    socket.emit('client:joined', {
      hostInfo: session.hostInfo,
      turn: issueTurnCredential()
    });
    io.to(session.hostSocketId).emit('host:client-joined', {
      clientInfo: {
        name: deviceName || '手机',
        id: socket.id,
        deviceId: deviceId || null,
        activationCode: activationCode || null,
        shareToken: shareToken || null,
        version: version || null
      },
      turn: issueTurnCredential()
    });
    console.log(`[配对] ${deviceName || '手机'}${version ? ' v' + version : ''} → ${pairCode} → ${session.hostInfo.name}${session.hostInfo.version ? ' v' + session.hostInfo.version : ''}`);
    log(`[配对] 成功: ${deviceName || '手机'}${version ? ' v' + version : ''} (socket=${socket.id}, deviceId=${deviceId || '无'}, activationCode=${activationCode ? '有' : '无'}) → 电脑=${session.hostInfo.name}${session.hostInfo.version ? ' v' + session.hostInfo.version : ''} (socket=${session.hostSocketId})`);
  }

  socket.on('client:join', (msg) => {
      const m = msg || {};
      // v2.9+：手机端扫码共享二维码实际走 client:join（配对码 + shareToken），
      // 与 client:join-by-share 同效，此处同样记录扫码加入绑定；
      // 配对码有效 = 有权访问该电脑，绑定仅是订阅标记（共享删除后自然消失）
      const st = String(m.shareToken || '');
      const share = st ? shareRegistry[st] : null;
      if (share && share.pairCode && m.deviceId) {
        const deviceId = String(m.deviceId);
        // v2.12+：扫码即绑定（共享码本身即连接凭证），不再签发访客令牌；
        // 绑定记录使共享出现在「共享给我的」并可免令牌重连（与 mine 同口径）
        joinRelations[deviceId] = joinRelations[deviceId] || {};
        if (!joinRelations[deviceId][st]) {
          log(`[共享] 记录扫码加入(join): ${deviceId} → ${share.name}`);
        }
        joinRelations[deviceId][st] = Date.now();
        saveJoinRelations();
      }
      joinClient(socket, { ...m });
    });

  // v2.6+：免配对码加入——手机端凭共享 token 直接连接共享所在电脑
  // 校验：token 存在于共享注册表，且 targetDeviceId 与激活设备匹配
  // 空消息防御：恶意/异常客户端发空 body 会触发解构崩溃，必须先判空
  socket.on('client:join-by-share', (msg) => {
    const { token, deviceId, deviceToken, version, deviceName } = msg || {};
    // v2.7+ 强制升级：旧版手机端（低于最低可用版本）拒绝免配对码连接
    if (!version || verNum(version) < verNum(MIN_ANDROID_VERSION)) {
      log(`[强制升级] 拒绝旧版手机端免配对码连接: ${deviceName || '手机'} v${version || '未知'}`);
      return socket.emit('client:error', { reason: 'APP_VERSION_REQUIRED', latest: ANDROID_VERSION });
    }
    const share = shareRegistry[token];
    if (!share || !share.pairCode) {
      log(`[共享] 加入失败: 共享不存在或已失效 token=${token}`);
      return socket.emit('client:error', { reason: '共享不存在或已失效' });
    }
    const rec = deviceId ? actDevices[deviceId] : null;
    // v2.12+：绑定设备（曾凭共享码加入，join-relations 有记录）免令牌放行——
    // 共享码本身即凭证，绑定即授权（与 mine 列表同口径）；定向共享不放行
    const bound = !!deviceId && !!joinRelations[deviceId] &&
        !!joinRelations[deviceId][token] && !share.targetDeviceId;
    if ((!rec || rec.token !== deviceToken) && !bound) {
      log(`[共享] 加入失败: 设备令牌无效 ${deviceId}`);
      return socket.emit('client:error', { reason: '设备令牌无效，请重新激活' });
    }
    if (share.targetDeviceId && share.targetDeviceId !== deviceId) {
      log(`[共享] 加入失败: ${deviceId} 无权访问 ${share.name}`);
      return socket.emit('client:error', { reason: '无权访问该共享' });
    }
    // v2.8+：记录扫码加入绑定，使该共享持久化出现在“共享给我的”列表
    joinRelations[deviceId] = joinRelations[deviceId] || {};
    if (!joinRelations[deviceId][token]) {
      log(`[共享] 记录扫码加入: ${deviceId} → ${share.name}`);
    }
    joinRelations[deviceId][token] = Date.now();
    saveJoinRelations();
    joinClient(socket, {
      pairCode: share.pairCode,
      deviceName: deviceName || '手机',
      deviceId: deviceId || null,
      shareToken: token,
      version: version || null
    });
  });

  // 信令转发: 主机 → 客户端（多客户端时带 to 指定目标；不带则转发给唯一客户端）
  // 空消息防御：发空 body 会触发解构崩溃
  socket.on('signal:host→client', (msg) => {
    const { signal, to } = msg || {};
    const session = sessions.get(socket.pairCode);
    log(`[信令] 电脑→手机 type=${signal?.type} 长度=${JSON.stringify(signal || '').length}`);
    if (!session?.clients) return;
    if (to && session.clients.has(to)) {
      io.to(to).emit('signal:server→client', { signal });
    } else if (session.clients.size === 1) {
      io.to([...session.clients.keys()][0]).emit('signal:server→client', { signal });
    }
  });

  // 信令转发: 客户端 → 主机
  // 空消息防御：发空 body 会触发解构崩溃
  socket.on('signal:client→host', (msg) => {
    const { signal } = msg || {};
    const session = sessions.get(socket.pairCode);
    log(`[信令] 手机→电脑 type=${signal?.type} 长度=${JSON.stringify(signal || '').length}`);
    if (session) {
      io.to(session.hostSocketId).emit('signal:server→host', { signal, from: socket.id });
    }
  });

  // 管理员踢出指定客户端（仅主机可调用）
  // 空消息防御：发空 body 会触发解构崩溃
  socket.on('admin:kick', (msg) => {
    const { clientId } = msg || {};
    if (socket.role !== 'host' || !socket.pairCode) return;
    const session = sessions.get(socket.pairCode);
    if (!session?.clients || !session.clients.has(clientId)) return;
    log(`[踢出] 管理员踢出客户端: ${clientId}`);
    io.to(clientId).emit('peer:kicked', { reason: '已被管理员移出' });
    session.clients.delete(clientId);
    const target = io.sockets.sockets.get(clientId);
    if (target) target.disconnect(true);
  });

  // 断开连接
  socket.on('disconnect', () => {
    if (!socket.pairCode) return;
    const session = sessions.get(socket.pairCode);
    if (!session) return;

    if (socket.role === 'host') {
      // 若该连接已被新连接替换（主机刷新重连），不再处理旧连接的断开
      if (session.hostSocketId !== socket.id) return;
      // 电脑端断开：通知所有手机端断开；保留会话（配对码不变），
      // 电脑端 socket 自动重连重新 register 时覆盖，手机端自动重连 join 即可恢复
      log(`[断开] 电脑端: ${socket.id} code=${socket.pairCode}`);
      if (session.clients) {
        for (const cid of session.clients.keys()) {
          io.to(cid).emit('peer:disconnected');
        }
      }
    } else if (socket.role === 'client') {
      // 手机端断开：通知电脑端（带 clientId 区分是哪个手机）；保留会话，
      // 手机端断线重连可用同一配对码直接重新 join
      const info = session.clients?.get(socket.id);
      if (!info) return; // 已被新连接替换，不再通知
      log(`[断开] 手机端: ${socket.id} code=${socket.pairCode}`);
      session.clients.delete(socket.id);
      io.to(session.hostSocketId).emit('peer:disconnected', {
        clientId: socket.id,
        deviceId: info.deviceId || null
      });
    }
    log(`[断开] ${socket.id}`);
  });
});

// ── 启动 ─────────────────────────────────────────────────────
// 日志同时写入 server.log（终端日志易丢失，测试阶段落盘便于回溯）
const LOG_FILE = join(process.cwd(), 'server.log');
{
  const _stdoutWrite = process.stdout.write.bind(process.stdout);
  const _stderrWrite = process.stderr.write.bind(process.stderr);
  process.stdout.write = (chunk, ...rest) => {
    try { writeFileSync(LOG_FILE, String(chunk), { flag: 'a' }); } catch {}
    return _stdoutWrite(chunk, ...rest);
  };
  process.stderr.write = (chunk, ...rest) => {
    try { writeFileSync(LOG_FILE, String(chunk), { flag: 'a' }); } catch {}
    return _stderrWrite(chunk, ...rest);
  };
}

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n╔══════════════════════════════════════════╗`);
  console.log(`║   无限大盘                                 ║`);
  console.log(`╠══════════════════════════════════════════╣`);
  console.log(`║  版本: v${SERVER_VERSION}${' '.repeat(Math.max(1, 20 - SERVER_VERSION.length))}║`);
  console.log(`║  本机: http://localhost:${PORT}              ║`);
  console.log(`║  后台: http://localhost:${PORT}/admin        ║`);
  console.log(`║  激活: 电脑端发放激活码(管理员/普通)║`);
  console.log(`╚══════════════════════════════════════════╝\n`);
});

// 兼容历史客户端保存的 48828 端口（早期版本默认服务器地址）：
// 注意：同一 http.Server 不能 listen 两次（第二次会覆盖第一次的绑定，
// 实测导致 3000 端口消失），必须新建 server 实例共享 app，并 attach
// Socket.IO 才能同时支持信令（否则兼容端口只有 HTTP 没有信令）
const LEGACY_PORT = 48828;
if (LEGACY_PORT !== PORT) {
  const legacyServer = createServer(app);
  io.attach(legacyServer); // 兼容端口同样提供 Socket.IO 信令
  legacyServer.listen(LEGACY_PORT, '0.0.0.0', () => {
    console.log(`[兼容] 历史端口 ${LEGACY_PORT} 已监听（兼容旧版客户端配置的服务器地址）`);
  });
}
