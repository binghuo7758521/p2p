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
import { randomBytes, scryptSync, timingSafeEqual, createHmac } from 'crypto';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
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
const SERVER_VERSION = '2.1';   // 服务器端版本
const DESKTOP_VERSION = '4.7';  // 电脑端版本
const ANDROID_VERSION = '4.4';  // 手机端版本

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
const DOWNLOADS_DIR = join(__dirname, 'downloads');
app.use('/downloads', express.static(DOWNLOADS_DIR));

// 版本号转数值（v1.5 → 1.5），用于大小比较
function verNum(v) {
  const n = parseFloat(String(v));
  return Number.isNaN(n) ? 0 : n;
}

// 升级检查：/update-check?platform=desktop|android&version=x.y
// 返回最新版本、是否需要升级、下载地址、更新说明
app.get('/update-check', (req, res) => {
  const platform = req.query.platform === 'android' ? 'android' : 'desktop';
  const current = String(req.query.version || '');
  const latest = platform === 'android' ? ANDROID_VERSION : DESKTOP_VERSION;
  const file = platform === 'android' ? 'app-release.apk' : 'p2p_desktop.zip';
  const filePath = join(DOWNLOADS_DIR, file);
  const hasFile = existsSync(filePath);
  const needUpdate = hasFile && verNum(latest) > verNum(current);
  res.json({
    platform,
    current,
    latest,
    needUpdate,
    url: hasFile ? `/downloads/${file}` : null,
    notes: hasFile ? `升级到 v${latest}（服务器已就绪）` : ''
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

function generatePairCode() {
  // 生成新的配对码并持久化
  const bytes = randomBytes(PAIR_CODE_LENGTH);
  let code = '';
  for (let i = 0; i < PAIR_CODE_LENGTH; i++) {
    code += PAIR_CODE_CHARS[bytes[i] % PAIR_CODE_CHARS.length];
  }
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

// ── 用户数据存储 ─────────────────────────────────────────────
const USERS_FILE = join(process.cwd(), 'users.json');
const TOKENS_FILE = join(process.cwd(), 'tokens.json');

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
  socket.on('host:register', ({ deviceName, desktop, version }) => {
    const pairCode = getOrCreatePairCode();
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
      hostInfo: { name: deviceName || '电脑', id: socket.id, desktop: desktop || null, version: version || null },
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

  // 重新生成配对码（仅主机可用）：旧码失效，新码广播给所有已注册主机
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
    const newCode = generatePairCode();
    sessions.set(newCode, {
      hostSocketId: socket.id,
      clients: new Map(),
      hostInfo: oldSession?.hostInfo || { name: '电脑', id: socket.id },
      createdAt: Date.now()
    });
    socket.pairCode = newCode;
    io.emit('pair:code-changed', { pairCode: newCode });
    console.log(`[配对码] ${oldCode} → 重新生成 ${newCode}`);
  });

  // 手机端通过配对码加入（支持多客户端：deviceId 设备标识 / shareToken 共享码 / phone 登录手机号）
  // version：手机端上报的版本号，记录于配对日志便于排查版本差异
  socket.on('client:join', ({ pairCode, deviceName, deviceId, shareToken, phone, version }) => {
    let session = sessions.get(pairCode);
    if (!session || !session.hostSocketId || !io.sockets.sockets.has(session.hostSocketId)) {
      // 会话不存在或主机 socket 已死（电脑端离线/服务器重启后未注册）：
      // 若配对码仍是当前有效码 → host-offline（手机端自动等待电脑端上线重试）；
      // 否则配对码已被重新生成 → 无效，需重新扫码
      const current = getCurrentPairCode();
      if (current && pairCode === current) {
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
      log(`[无效] 配对码无效: ${deviceName} 请求码=${pairCode} 当前码=${current || '无'}`);
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
