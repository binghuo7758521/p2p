/**
 * P2P 文件存取系统 — 信令服务器
 * 
 * 功能：
 * 1. 10位配对码（大写字母+数字），设备配对
 * 2. WebRTC SDP/ICE 信令转发
 * 3. 托管前端静态文件
 * 4. 手机用户体系：短信验证码注册 / 登录（Token 认证，30 天有效）
 * 5. 后台管理 API：用户管理 + 系统运行状态
 * 
 * 环境变量（占位配置）：
 *   SMS_DEV=1            开发模式：验证码直接返回，不发真实短信
 *   ALIYUN_ACCESS_KEY_ID       阿里云 AccessKey ID
 *   ALIYUN_ACCESS_KEY_SECRET   阿里云 AccessKey Secret
 *   ALIYUN_SMS_SIGN_NAME       阿里云短信认证-赠送签名名称（控制台赠送签名配置页）
 *   ALIYUN_SMS_TEMPLATE_CODE   阿里云短信认证-赠送模板CODE（如 100001）
 *   OSS_BASE_URL               升级包对象存储域名（如 https://xxx.oss-cn-hangzhou.aliyuncs.com，
 *                              配置后 /downloads 302 重定向到 OSS，升级包不占 ECS 带宽）
 * 
 * 短信能力：阿里云短信认证服务（号码认证产品线 Dypnsapi）
 *   - 发送: SendSmsVerifyCode（验证码由系统生成，官方可核验）
 *   - 核验: CheckSmsVerifyCode（VerifyResult=PASS 通过）
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
const SERVER_VERSION = '2.5';   // 服务器端版本
const DESKTOP_VERSION = '5.8';  // 电脑端版本
const ANDROID_VERSION = '5.3';  // 手机端版本

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
// 请求体为日志纯文本（text/plain），query 携带 deviceId/version/phone
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

// 电脑端升级包 MD5 缓存（静默升级完整性校验；按文件大小变化失效）
// 发布时需同时将升级包上传到 downloads 目录，否则返回 null（客户端拒绝静默升级）
let zipMd5Cache = { file: '', size: -1, md5: '' };
function desktopZipMd5() {
  const p = join(DOWNLOADS_DIR, 'p2p_desktop.zip');
  if (!existsSync(p)) return null;
  const size = statSync(p).size;
  if (zipMd5Cache.file === p && zipMd5Cache.size === size) return zipMd5Cache.md5;
  const h = createHash('md5');
  h.update(readFileSync(p));
  const md5 = h.digest('hex');
  zipMd5Cache = { file: p, size, md5 };
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

// 版本号转数值（v1.5 → 1.5），用于大小比较
function verNum(v) {
  const n = parseFloat(String(v));
  return Number.isNaN(n) ? 0 : n;
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
  res.json({
    platform,
    current,
    latest,
    needUpdate,
    url: hasFile ? `/downloads/${file}` : null,
    // 手机端升级提示附带安装引导：v5.0 及以下老版本无安装权限引导，
    // 需用户先在系统设置手动开启“安装未知应用”（Android 8+ 硬前提）
    notes: hasFile
        ? (platform === 'android'
            ? `升级到 v${latest}；若安装界面未弹出，请在 系统设置-应用-P2P 文件助手-安装未知应用 中允许后重试`
            : `升级到 v${latest}（服务器已就绪）`)
        : '',
    // 电脑端升级包 MD5：客户端静默升级完整性校验（无 MD5 时客户端回退手动下载）
    md5: platform === 'desktop' && hasFile ? desktopZipMd5() : null
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
// 电脑端创建/删除/修改共享时全量同步到服务器，手机端登录后按手机号
// 拉取“共享给我的”列表，并通过 client:join-by-share 免配对码连接电脑端。
// shareRegistry: { token: { token, deviceId, pairCode, hostName, name,
//   folder, perms[], targetPhone|null, createdAt, updatedAt } }
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
      targetPhone: s.targetPhone ? String(s.targetPhone).slice(0, 20) : null,
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

// 用户库: { users: [{ phone, salt, hash, status, createdAt, lastLoginAt }], admin: { username, salt, hash, createdAt } }
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

function createToken(phone, role) {
  const token = randomBytes(24).toString('hex');
  tokens[token] = { phone, role, createdAt: Date.now() };
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

// ── 短信验证码（阿里云短信认证服务） ──────────────────────────
const smsCodes = new Map(); // phone -> { code, expiresAt, lastSentAt }（仅开发模式使用）
const SMS_TTL_MS = 5 * 60 * 1000; // 验证码 5 分钟有效
const SMS_RESEND_MS = 60 * 1000; // 60 秒内不可重复发送

/**
 * 发送短信验证码（阿里云短信认证服务 SendSmsVerifyCode）。
 * SMS_DEV=1 时本地生成验证码并直接返回（开发/演示模式）；
 * 否则验证码由阿里云系统生成并下发短信（TemplateParam 使用 ##code## 占位符，可被官方核验）。
 */
async function sendSmsCode(phone) {
  if (process.env.SMS_DEV === '1') {
    const code = String(Math.floor(100000 + Math.random() * 900000));
    console.log(`[短信][开发模式] ${phone} 验证码: ${code}`);
    return { ok: true, code };
  }
  try {
    if (!process.env.ALIYUN_ACCESS_KEY_ID || !process.env.ALIYUN_ACCESS_KEY_SECRET || !process.env.ALIYUN_SMS_SIGN_NAME || !process.env.ALIYUN_SMS_TEMPLATE_CODE) {
      return { ok: false, error: '短信服务未配置：请设置 ALIYUN_ACCESS_KEY_ID/SECRET、ALIYUN_SMS_SIGN_NAME、ALIYUN_SMS_TEMPLATE_CODE（开发模式请设置 SMS_DEV=1）' };
    }
    const Dypnsapi = (await import('@alicloud/dypnsapi20170525')).default;
    const OpenApi = (await import('@alicloud/openapi-client')).default;

    const config = new OpenApi.Config({
      accessKeyId: process.env.ALIYUN_ACCESS_KEY_ID,
      accessKeySecret: process.env.ALIYUN_ACCESS_KEY_SECRET,
    });
    config.endpoint = 'dypnsapi.aliyuncs.com';
    const client = new Dypnsapi.default(config);

    const req = new Dypnsapi.SendSmsVerifyCodeRequest({
      phoneNumber: phone,
      signName: process.env.ALIYUN_SMS_SIGN_NAME,
      templateCode: process.env.ALIYUN_SMS_TEMPLATE_CODE,
      templateParam: JSON.stringify({ code: '##code##', min: '5' }),
      codeLength: 6,   // 6 位验证码
      codeType: 1,     // 纯数字
      validTime: 300,  // 5 分钟有效
      interval: 60,    // 60 秒频控
    });
    const resp = await client.sendSmsVerifyCode(req);
    if (resp.body.code === 'OK') return { ok: true };
    return { ok: false, error: `阿里云短信认证: ${resp.body.code} ${resp.body.message}` };
  } catch (e) {
    return { ok: false, error: `短信发送失败: ${e.message || e}` };
  }
}

/**
 * 核验短信验证码。
 * 开发模式：内存比对；生产模式：调用 CheckSmsVerifyCode 官方核验（VerifyResult=PASS 通过）。
 */
async function verifySmsCode(phone, code) {
  if (process.env.SMS_DEV === '1') {
    const rec = smsCodes.get(phone);
    if (!rec) return { ok: false, error: '请先获取验证码' };
    if (rec.code !== code) return { ok: false, error: '验证码错误' };
    if (Date.now() > rec.expiresAt) {
      smsCodes.delete(phone);
      return { ok: false, error: '验证码已过期，请重新获取' };
    }
    smsCodes.delete(phone);
    return { ok: true };
  }
  try {
    if (!process.env.ALIYUN_ACCESS_KEY_ID || !process.env.ALIYUN_ACCESS_KEY_SECRET) {
      return { ok: false, error: '短信服务未配置：请设置 ALIYUN_ACCESS_KEY_ID/SECRET（开发模式请设置 SMS_DEV=1）' };
    }
    const Dypnsapi = (await import('@alicloud/dypnsapi20170525')).default;
    const OpenApi = (await import('@alicloud/openapi-client')).default;

    const config = new OpenApi.Config({
      accessKeyId: process.env.ALIYUN_ACCESS_KEY_ID,
      accessKeySecret: process.env.ALIYUN_ACCESS_KEY_SECRET,
    });
    config.endpoint = 'dypnsapi.aliyuncs.com';
    const client = new Dypnsapi.default(config);

    const req = new Dypnsapi.CheckSmsVerifyCodeRequest({
      phoneNumber: phone,
      verifyCode: code,
    });
    const resp = await client.checkSmsVerifyCode(req);
    if (resp.body.code !== 'OK') {
      return { ok: false, error: `核验服务异常: ${resp.body.code} ${resp.body.message}` };
    }
    if (resp.body.model?.verifyResult === 'PASS') return { ok: true };
    return { ok: false, error: '验证码错误或已过期' };
  } catch (e) {
    const errCode = String(e.code || '');
    if (errCode === 'isv.ValidateFail') return { ok: false, error: '验证码错误或已过期' };
    return { ok: false, error: `验证码核验失败: ${e.message || e}` };
  }
}

// ── 认证中间件 ───────────────────────────────────────────────
// 手机用户认证
function requireUser(req, res, next) {
  const info = getTokenInfo(req);
  if (!info) return res.status(401).json({ ok: false, error: '未登录或登录已过期' });
  if (info.role !== 'user') return res.status(403).json({ ok: false, error: '无权限' });
  const user = db.users.find((u) => u.phone === info.phone);
  if (!user) return res.status(401).json({ ok: false, error: '用户不存在' });
  if (user.status !== 'active') return res.status(403).json({ ok: false, error: '账号已被禁用' });
  req.user = user;
  next();
}

// 管理员认证
function requireAdmin(req, res, next) {
  const info = getTokenInfo(req);
  if (!info) return res.status(401).json({ ok: false, error: '未登录或登录已过期' });
  if (info.role !== 'admin') return res.status(403).json({ ok: false, error: '无管理员权限' });
  next();
}

// ── 手机用户 API ─────────────────────────────────────────────
// 发送注册验证码
app.post('/api/sms/send', async (req, res) => {
  try {
    const phone = String(req.body?.phone || '').trim();
    if (!/^1\d{10}$/.test(phone)) {
      log(`[验证码] 拒绝: 手机号格式不正确 ${phone}`);
      return res.json({ ok: false, error: '手机号格式不正确' });
    }
    const prev = smsCodes.get(phone);
    if (prev && Date.now() - prev.lastSentAt < SMS_RESEND_MS) {
      log(`[验证码] 拒绝: 发送过于频繁 ${phone}`);
      return res.json({ ok: false, error: '发送过于频繁，请 1 分钟后再试' });
    }
    const result = await sendSmsCode(phone);
    if (!result.ok) return res.json({ ok: false, error: result.error });
    if (process.env.SMS_DEV === '1') {
      smsCodes.set(phone, { code: result.code, expiresAt: Date.now() + SMS_TTL_MS, lastSentAt: Date.now() });
      console.log(`[验证码] ${phone} 已发送（开发模式，${SMS_TTL_MS / 60000} 分钟内有效）`);
    } else {
      console.log(`[验证码] ${phone} 短信已下发（阿里云短信认证服务）`);
    }
    res.json({ ok: true, devCode: result.code }); // devCode 仅开发模式返回
  } catch (e) {
    console.error('[短信] 发送异常:', e);
    res.json({ ok: false, error: '服务器异常，请稍后再试' });
  }
});

// 注册新用户（需短信验证码，阿里云短信认证服务核验）
app.post('/api/register', async (req, res) => {
  try {
    const phone = String(req.body?.phone || '').trim();
    const code = String(req.body?.code || '').trim();
    const password = String(req.body?.password || '');
    if (!/^1\d{10}$/.test(phone)) {
      log(`[注册] 拒绝: 手机号格式不正确 ${phone}`);
      return res.json({ ok: false, error: '手机号格式不正确' });
    }
    if (!/^\d{6}$/.test(code)) {
      log(`[注册] 拒绝: 验证码格式不正确 ${phone}`);
      return res.json({ ok: false, error: '验证码为 6 位数字' });
    }
    if (password.length < 6) {
      log(`[注册] 拒绝: 密码过短 ${phone}`);
      return res.json({ ok: false, error: '密码至少 6 位' });
    }
    if (db.users.some((u) => u.phone === phone)) {
      log(`[注册] 拒绝: 手机号已注册 ${phone}`);
      return res.json({ ok: false, error: '该手机号已注册，请直接登录' });
    }
    const v = await verifySmsCode(phone, code);
    if (!v.ok) {
      log(`[注册] 失败: 验证码核验未通过 ${phone} (${v.error})`);
      return res.json({ ok: false, error: v.error });
    }
    db.users.push({
      phone,
      ...hashPassword(password),
      status: 'active',
      createdAt: Date.now(),
      lastLoginAt: null,
    });
    saveJson(USERS_FILE, db);
    const token = createToken(phone, 'user');
    console.log(`[注册] 新用户 ${phone}`);
    res.json({ ok: true, token, phone });
  } catch (e) {
    console.error('[注册] 异常:', e);
    res.json({ ok: false, error: '服务器异常，请稍后再试' });
  }
});

// 登录
app.post('/api/login', (req, res) => {
  const phone = String(req.body?.phone || '').trim();
  const password = String(req.body?.password || '');
  const user = db.users.find((u) => u.phone === phone);
  if (!user) {
    log(`[登录] 失败: 用户不存在 ${phone}`);
    return res.json({ ok: false, error: '手机号或密码错误' });
  }
  if (user.status !== 'active') {
    log(`[登录] 失败: 账号已禁用 ${phone}`);
    return res.json({ ok: false, error: '账号已被禁用，请联系管理员' });
  }
  if (!verifyPassword(password, user.salt, user.hash)) {
    log(`[登录] 失败: 密码错误 ${phone}`);
    return res.json({ ok: false, error: '手机号或密码错误' });
  }
  user.lastLoginAt = Date.now();
  saveJson(USERS_FILE, db);
  const token = createToken(phone, 'user');
  log(`[登录] 成功: ${phone}`);
  res.json({ ok: true, token, phone });
});

// 重置密码（需短信验证码核验，验证码发送复用 /api/sms/send）
app.post('/api/reset-password', async (req, res) => {
  try {
    const phone = String(req.body?.phone || '').trim();
    const code = String(req.body?.code || '').trim();
    const password = String(req.body?.password || '');
    if (!/^1\d{10}$/.test(phone)) {
      log(`[重置密码] 拒绝: 手机号格式不正确 ${phone}`);
      return res.json({ ok: false, error: '手机号格式不正确' });
    }
    if (!/^\d{6}$/.test(code)) {
      log(`[重置密码] 拒绝: 验证码格式不正确 ${phone}`);
      return res.json({ ok: false, error: '验证码为 6 位数字' });
    }
    if (password.length < 6) {
      log(`[重置密码] 拒绝: 密码过短 ${phone}`);
      return res.json({ ok: false, error: '密码至少 6 位' });
    }
    const user = db.users.find((u) => u.phone === phone);
    if (!user) {
      log(`[重置密码] 失败: 用户不存在 ${phone}`);
      return res.json({ ok: false, error: '该手机号未注册' });
    }
    if (user.status !== 'active') {
      log(`[重置密码] 失败: 账号已禁用 ${phone}`);
      return res.json({ ok: false, error: '账号已被禁用，请联系管理员' });
    }
    const v = await verifySmsCode(phone, code);
    if (!v.ok) {
      log(`[重置密码] 失败: 验证码核验未通过 ${phone} (${v.error})`);
      return res.json({ ok: false, error: v.error });
    }
    Object.assign(user, hashPassword(password));
    // 安全策略：重置后使该用户所有 token 失效，需重新登录
    let revoked = 0;
    for (const [t, info] of Object.entries(tokens)) {
      if (info.phone === phone) {
        delete tokens[t];
        revoked++;
      }
    }
    if (revoked > 0) saveTokens();
    saveJson(USERS_FILE, db);
    console.log(`[重置密码] 成功: ${phone}（已使 ${revoked} 个旧 token 失效）`);
    res.json({ ok: true });
  } catch (e) {
    console.error('[重置密码] 异常:', e);
    res.json({ ok: false, error: '服务器异常，请稍后再试' });
  }
});

// 当前登录用户信息
app.get('/api/user/me', requireUser, (req, res) => {
  res.json({
    ok: true,
    phone: req.user.phone,
    createdAt: req.user.createdAt,
    lastLoginAt: req.user.lastLoginAt,
  });
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

// 手机端：登录后拉取“共享给我的”文件夹列表（按登录手机号匹配）
// 返回在线状态（电脑端在线可立即连接），不暴露共享目录绝对路径
app.get('/api/shares/mine', requireUser, (req, res) => {
  const phone = req.user.phone;
  const list = [];
  for (const s of Object.values(shareRegistry)) {
    if (!s.targetPhone || s.targetPhone !== phone) continue;
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
  log(`[共享] 手机端查询: ${phone} 共 ${list.length} 条`);
  res.json({ ok: true, shares: list });
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

// 用户列表（支持手机号模糊搜索）
app.get('/api/admin/users', requireAdmin, (req, res) => {
  const kw = (req.query.keyword || '').trim();
  let list = db.users;
  if (kw) list = list.filter((u) => u.phone.includes(kw));
  list = [...list].sort((a, b) => b.createdAt - a.createdAt);
  res.json({
    ok: true,
    users: list.map((u) => ({
      phone: u.phone,
      status: u.status,
      createdAt: u.createdAt,
      lastLoginAt: u.lastLoginAt,
    })),
  });
});

// 启用 / 禁用用户
app.post('/api/admin/users/:phone/status', requireAdmin, (req, res) => {
  const user = db.users.find((u) => u.phone === String(req.params.phone));
  if (!user) return res.json({ ok: false, error: '用户不存在' });
  const status = String(req.body?.status || '');
  if (status !== 'active' && status !== 'disabled') return res.json({ ok: false, error: '状态无效' });
  user.status = status;
  saveJson(USERS_FILE, db);
  console.log(`[管理] 用户 ${req.params.phone} → ${status === 'active' ? '启用' : '禁用'}`);
  res.json({ ok: true });
});

// 删除用户（同时清除其 token）
app.delete('/api/admin/users/:phone', requireAdmin, (req, res) => {
  const idx = db.users.findIndex((u) => u.phone === String(req.params.phone));
  if (idx < 0) return res.json({ ok: false, error: '用户不存在' });
  db.users.splice(idx, 1);
  let changed = false;
  for (const [t, info] of Object.entries(tokens)) {
    if (info.phone === req.params.phone) {
      delete tokens[t];
      changed = true;
    }
  }
  saveJson(USERS_FILE, db);
  if (changed) saveTokens();
  console.log(`[管理] 删除用户 ${req.params.phone}`);
  res.json({ ok: true });
});

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
  socket.on('host:register', ({ deviceName, desktop, version, deviceId, hostToken }) => {
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
            phone: info?.phone || null,
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

  // 手机端通过配对码加入（支持多客户端：deviceId 设备标识 / shareToken 共享码 / phone 登录手机号）
  // version：手机端上报的版本号，记录于配对日志便于排查版本差异
    // 手机端加入公共流程：配对码（client:join）与共享码（client:join-by-share）
  // 两种入口复用同一路由逻辑（免配对码连接由服务器按共享注册表解析出 pairCode）
  function joinClient(socket, { pairCode, deviceName, deviceId, shareToken, phone, version }) {
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
          phone: phone || null,
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
      phone: phone || null,
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
        phone: phone || null,
        shareToken: shareToken || null,
        version: version || null
      },
      turn: issueTurnCredential()
    });
    console.log(`[配对] ${deviceName || '手机'}${version ? ' v' + version : ''} → ${pairCode} → ${session.hostInfo.name}${session.hostInfo.version ? ' v' + session.hostInfo.version : ''}`);
    log(`[配对] 成功: ${deviceName || '手机'}${version ? ' v' + version : ''} (socket=${socket.id}, deviceId=${deviceId || '无'}, phone=${phone || '无'}) → 电脑=${session.hostInfo.name}${session.hostInfo.version ? ' v' + session.hostInfo.version : ''} (socket=${session.hostSocketId})`);
  }

  socket.on('client:join', (msg) => joinClient(socket, msg));

  // v2.4+：免配对码加入——手机端凭共享 token 直接连接共享所在电脑
  // 校验：token 存在于共享注册表，且 targetPhone 与登录手机号匹配
  socket.on('client:join-by-share', ({ token, deviceId, phone, version, deviceName }) => {
    const share = shareRegistry[token];
    if (!share || !share.pairCode) {
      log(`[共享] 加入失败: 共享不存在或已失效 token=${token}`);
      return socket.emit('client:error', { reason: '共享不存在或已失效' });
    }
    if (share.targetPhone && share.targetPhone !== phone) {
      log(`[共享] 加入失败: ${phone} 无权访问 ${share.name}`);
      return socket.emit('client:error', { reason: '无权访问该共享' });
    }
    joinClient(socket, {
      pairCode: share.pairCode,
      deviceName: deviceName || '手机',
      deviceId: deviceId || null,
      shareToken: token,
      phone: phone || null,
      version: version || null
    });
  });

  // 信令转发: 主机 → 客户端（多客户端时带 to 指定目标；不带则转发给唯一客户端）
  socket.on('signal:host→client', ({ signal, to }) => {
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
  socket.on('signal:client→host', ({ signal }) => {
    const session = sessions.get(socket.pairCode);
    log(`[信令] 手机→电脑 type=${signal?.type} 长度=${JSON.stringify(signal || '').length}`);
    if (session) {
      io.to(session.hostSocketId).emit('signal:server→host', { signal, from: socket.id });
    }
  });

  // 管理员踢出指定客户端（仅主机可调用）
  socket.on('admin:kick', ({ clientId }) => {
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
  console.log(`║   P2P 文件存取系统                         ║`);
  console.log(`╠══════════════════════════════════════════╣`);
  console.log(`║  版本: v${SERVER_VERSION}${' '.repeat(Math.max(1, 20 - SERVER_VERSION.length))}║`);
  console.log(`║  本机: http://localhost:${PORT}              ║`);
  console.log(`║  后台: http://localhost:${PORT}/admin        ║`);
    const smsStatus = process.env.SMS_DEV === '1'
      ? '开发模式(验证码直返)'
      : (process.env.ALIYUN_ACCESS_KEY_ID && process.env.ALIYUN_SMS_SIGN_NAME && process.env.ALIYUN_SMS_TEMPLATE_CODE)
        ? `阿里云短信认证(签名:${process.env.ALIYUN_SMS_SIGN_NAME})`
        : '阿里云(待配置)';
    console.log(`║  短信: ${smsStatus}${' '.repeat(Math.max(1, 18 - smsStatus.length))}║`);
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
