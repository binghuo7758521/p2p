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
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const app = express();
app.use(express.json({ limit: '1mb' }));
const server = createServer(app);
const io = new Server(server, {
  cors: { origin: '*' },
  pingInterval: 10000,
  pingTimeout: 5000
});

const PORT = process.env.PORT || 3000;

// ── 会话存储 ─────────────────────────────────────────────────
const sessions = new Map();
const PAIR_CODE_FILE = join(process.cwd(), '.pair-code');

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
    if (!/^1\d{10}$/.test(phone)) return res.json({ ok: false, error: '手机号格式不正确' });
    const prev = smsCodes.get(phone);
    if (prev && Date.now() - prev.lastSentAt < SMS_RESEND_MS) {
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
    if (!/^1\d{10}$/.test(phone)) return res.json({ ok: false, error: '手机号格式不正确' });
    if (!/^\d{6}$/.test(code)) return res.json({ ok: false, error: '验证码为 6 位数字' });
    if (password.length < 6) return res.json({ ok: false, error: '密码至少 6 位' });
    if (db.users.some((u) => u.phone === phone)) {
      return res.json({ ok: false, error: '该手机号已注册，请直接登录' });
    }
    const v = await verifySmsCode(phone, code);
    if (!v.ok) return res.json({ ok: false, error: v.error });
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
  if (!user) return res.json({ ok: false, error: '手机号或密码错误' });
  if (user.status !== 'active') return res.json({ ok: false, error: '账号已被禁用，请联系管理员' });
  if (!verifyPassword(password, user.salt, user.hash)) {
    return res.json({ ok: false, error: '手机号或密码错误' });
  }
  user.lastLoginAt = Date.now();
  saveJson(USERS_FILE, db);
  const token = createToken(phone, 'user');
  res.json({ ok: true, token, phone });
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
  return {
    urls: [TURN_SERVER_URL, `${TURN_SERVER_URL}?transport=tcp`],
    username,
    credential,
  };
}

// ── Socket.IO 信令 ───────────────────────────────────────────
io.on('connection', (socket) => {
  console.log(`[连接] ${socket.id}`);

  // 电脑端注册为主机
  socket.on('host:register', ({ deviceName }) => {
    const pairCode = getOrCreatePairCode();
    const existing = sessions.get(pairCode);
    // 旧主机 socket 仍存活时才视为“新电脑抢占”，通知手机端断开；
    // 电脑端 socket 闪断重连（旧 socket 已死）：保留手机端会话与配对信息，
    // 不通知断开——P2P 数据通道不依赖信令服务器，手机端可继续传输
    const oldHostAlive = !!(existing &&
        existing.hostSocketId &&
        existing.hostSocketId !== socket.id &&
        io.sockets.sockets.has(existing.hostSocketId));
    if (oldHostAlive && existing.clientSocketId) {
      io.to(existing.clientSocketId).emit('peer:disconnected');
    }
    const clientSocketId =
        existing && !oldHostAlive ? existing.clientSocketId : null;
    sessions.set(pairCode, {
      hostSocketId: socket.id,
      clientSocketId,
      clientInfo: existing?.clientInfo ?? null,
      hostInfo: { name: deviceName || '电脑', id: socket.id },
      createdAt: existing?.createdAt ?? Date.now()
    });
    socket.pairCode = pairCode;
    socket.role = 'host';
    socket.emit('host:registered', { pairCode });
    console.log(`[注册] ${deviceName} → 配对码 ${pairCode}`);
  });

  // 重新生成配对码（仅主机可用）：旧码失效，新码广播给所有已注册主机
  socket.on('pair:reset', () => {
    if (socket.role !== 'host' || !socket.pairCode) return;
    const oldCode = socket.pairCode;
    const oldSession = sessions.get(oldCode);
    // 通知旧配对码下已连接的客户端断开
    if (oldSession?.clientSocketId) {
      io.to(oldSession.clientSocketId).emit('peer:disconnected');
    }
    sessions.delete(oldCode);
    const newCode = generatePairCode();
    sessions.set(newCode, {
      hostSocketId: socket.id,
      clientSocketId: null,
      hostInfo: oldSession?.hostInfo || { name: '电脑', id: socket.id },
      createdAt: Date.now()
    });
    socket.pairCode = newCode;
    io.emit('pair:code-changed', { pairCode: newCode });
    console.log(`[配对码] ${oldCode} → 重新生成 ${newCode}`);
  });

  // 手机端通过配对码加入
  socket.on('client:join', ({ pairCode, deviceName }) => {
    const session = sessions.get(pairCode);
    if (!session) return socket.emit('client:error', { reason: '配对码无效' });
    // 断线重连：同一配对码的旧 socket 被新连接替换（通知旧连接断开）
    if (session.clientSocketId && session.clientSocketId !== socket.id) {
      io.to(session.clientSocketId).emit('peer:disconnected');
    }

    session.clientSocketId = socket.id;
    session.clientInfo = { name: deviceName || '手机', id: socket.id };
    socket.pairCode = pairCode;
    socket.role = 'client';
    socket.hostSocketId = session.hostSocketId;

    socket.emit('client:joined', {
      hostInfo: session.hostInfo,
      turn: issueTurnCredential()
    });
    io.to(session.hostSocketId).emit('host:client-joined', {
      clientInfo: { name: deviceName || '手机', id: socket.id },
      turn: issueTurnCredential()
    });
    console.log(`[配对] ${deviceName} → ${pairCode} → ${session.hostInfo.name}`);
  });

  // 信令转发: 主机 → 客户端
  socket.on('signal:host→client', ({ signal }) => {
    const session = sessions.get(socket.pairCode);
    if (session?.clientSocketId) {
      io.to(session.clientSocketId).emit('signal:server→client', { signal });
    }
  });

  // 信令转发: 客户端 → 主机
  socket.on('signal:client→host', ({ signal }) => {
    const session = sessions.get(socket.pairCode);
    if (session) {
      io.to(session.hostSocketId).emit('signal:server→host', { signal });
    }
  });

  // 断开连接
  socket.on('disconnect', () => {
    if (!socket.pairCode) return;
    const session = sessions.get(socket.pairCode);
    if (!session) return;
    // 若该连接已被新连接替换（如主机刷新重连），不再处理旧连接的断开
    if (session.hostSocketId !== socket.id && session.clientSocketId !== socket.id) return;

    if (socket.role === 'host') {
      // 电脑端断开：通知手机端断开；保留会话（配对码不变），
      // 电脑端 socket 自动重连重新 register 时覆盖，手机端自动重连 join 即可恢复
      if (session.clientSocketId) {
        io.to(session.clientSocketId).emit('peer:disconnected');
      }
    } else if (socket.role === 'client') {
      // 手机端断开：通知电脑端；保留会话，仅清除 clientSocketId，
      // 手机端断线重连可用同一配对码直接重新 join
      io.to(session.hostSocketId).emit('peer:disconnected');
      session.clientSocketId = null;
      session.clientInfo = null;
    }
    console.log(`[断开] ${socket.id}`);
  });
});

// ── 启动 ─────────────────────────────────────────────────────
server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n╔══════════════════════════════════════════╗`);
  console.log(`║   P2P 文件存取系统                         ║`);
  console.log(`╠══════════════════════════════════════════╣`);
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
