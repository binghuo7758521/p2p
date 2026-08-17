// 身份体系 E2E 验证（v5.20）：激活码生命周期 / 配对码硬件分配 / 令牌撤销 /
// 多电脑管理员 / 共享访客绑定 / 版本门禁 / 后台管理
// 运行: node e2e_identity_test.cjs
// 幂等设计：所有激活码/共享token/deviceId 随机化，重复运行不依赖上次状态；
// 模拟电脑端 socket 保持在线直到用例结束；激活码/共享用后即清。
const { io } = require('socket.io-client');

const BASE = 'http://182.92.157.93:3000';
// 与 server.js 顶部同步（v5.21 验收目标）
const EXPECT = { server: '2.12', desktop: '6.15', android: '5.21' };
const MIN_VER = '5.21'; // 测试手机端上报版本（≥ MIN_ANDROID_VERSION 5.6）
const HOST_VER = '6.15'; // 测试电脑端上报版本
let pass = 0, fail = 0;

function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name} ${extra}`); }
}

async function getJson(url) {
  const r = await fetch(url);
  return { status: r.status, body: await r.json() };
}

async function postJson(path, body, token = '') {
  const r = await fetch(BASE + path, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json() };
}

// 随机 8 位激活码（字符集与电脑端生成规则一致，去 0/O、1/I）
const rnd = (n) => Array.from({ length: n },
    () => 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[Math.floor(Math.random() * 32)]).join('');
// 运行级唯一后缀：join-relations/act-devices 均持久化，手机端 deviceId 必须
// 每次运行随机化，否则旧绑定残留会触发 /api/shares/mine 的 bound 放行分支
const RUN = Date.now().toString(36) + rnd(4);
const PH = (tag) => `idtest-phone-${RUN}-${tag}`;

// 模拟手机端 join（client:join / client:join-by-share 通用）
function phoneJoin(payload, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    const t = setTimeout(() => { sock.close(); resolve({ event: 'TIMEOUT', raw: null }); }, timeoutMs);
    sock.on('connect', () => sock.emit(payload.joinByShare ? 'client:join-by-share' : 'client:join', {
      deviceName: 'e2e身份手机', version: MIN_VER, ...payload,
    }));
    sock.on('client:joined', (d) => { clearTimeout(t); sock.close(); resolve({ event: 'client:joined', raw: d }); });
    sock.on('client:error', (d) => { clearTimeout(t); sock.close(); resolve({ event: 'client:error', reason: d?.reason, raw: d }); });
    sock.on('connect_error', (e) => { clearTimeout(t); resolve({ event: 'CONNECT_ERROR', raw: String(e) }); });
  });
}

// 模拟电脑端注册（host:register）：holdOpen=true 保持在线供后续用例使用
function hostRegister(info, holdOpen = false, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    const t = setTimeout(() => { sock.close(); resolve({ pairCode: null, error: 'TIMEOUT' }); }, timeoutMs);
    sock.on('connect', () => sock.emit('host:register', {
      deviceName: info.deviceName || 'e2e身份电脑', desktop: true, version: HOST_VER,
      deviceId: info.deviceId, hostToken: info.hostToken,
      activationCodes: info.activationCodes || [],
    }));
    sock.on('host:registered', (d) => {
      clearTimeout(t);
      if (holdOpen) resolve({ pairCode: d.pairCode, sock });
      else { sock.close(); resolve({ pairCode: d.pairCode }); }
    });
    sock.on('connect_error', (e) => { clearTimeout(t); resolve({ pairCode: null, error: String(e) }); });
  });
}

// 电脑端同步激活码（host:sync-codes，增量覆盖该设备码表）
function syncCodes(hostSock, codes, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(false), timeoutMs);
    hostSock.emit('host:sync-codes', { codes });
    hostSock.once('host:codes-synced', () => { clearTimeout(t); resolve(true); });
  });
}

(async () => {
  console.log('── 1. 版本核对（v5.20 验收） ──');
  const v = await getJson(BASE + '/version');
  check(`server=${EXPECT.server} desktop=${EXPECT.desktop} android=${EXPECT.android}`,
    v.body.server === EXPECT.server && v.body.desktop === EXPECT.desktop && v.body.android === EXPECT.android,
    JSON.stringify(v.body));

  console.log('── 2. 激活码生命周期：一次性 / 状态查询三分支 / 撤销同步 ──');
  const codeA = 'ID' + rnd(6); // 8 位激活码
  const HOST_A = { deviceId: 'idtest-host-a', hostToken: 'idtest-host-token-a' };
  const ha = await hostRegister({ ...HOST_A, deviceName: 'e2e身份电脑A', activationCodes: [{ code: codeA, type: 'admin' }] }, true);
  check('电脑A注册成功', !!ha.pairCode, JSON.stringify({ pairCode: ha.pairCode }));
  const st0 = await getJson(BASE + `/api/activate-status?code=${codeA}`);
  check('未用激活码 → valid:true', st0.body.ok === true && st0.body.valid === true, JSON.stringify(st0.body));
  const ac1 = await postJson('/api/activate', { code: codeA, deviceId: PH('1'), version: MIN_VER });
  check('首次激活成功（pairCode/type/deviceToken 齐全）',
    ac1.body.ok === true && !!ac1.body.pairCode && ac1.body.type === 'admin' && !!ac1.body.deviceToken,
    JSON.stringify(ac1.body));
  const st1 = await getJson(BASE + `/api/activate-status?code=${codeA}`);
  check('已用激活码 → valid:false reason=used', st1.body.valid === false && st1.body.reason === 'used', JSON.stringify(st1.body));
  const ac2 = await postJson('/api/activate', { code: codeA, deviceId: PH('1b'), version: MIN_VER });
  check('同码二次激活 → 激活码已被使用', ac2.body.ok === false && ac2.body.error === '激活码已被使用', JSON.stringify(ac2.body));
  const st2 = await getJson(BASE + `/api/activate-status?code=${'ID' + rnd(6)}`);
  check('未注册码 → valid:false reason=invalid', st2.body.valid === false && st2.body.reason === 'invalid', JSON.stringify(st2.body));

  const codeB = 'ID' + rnd(6);
  await syncCodes(ha.sock, [{ code: codeB, type: 'admin' }]);
  const stB = await getJson(BASE + `/api/activate-status?code=${codeB}`);
  check('增量同步后新码生效 → valid:true', stB.body.valid === true, JSON.stringify(stB.body));
  await syncCodes(ha.sock, []); // 撤销全部码
  const stB2 = await getJson(BASE + `/api/activate-status?code=${codeB}`);
  check('撤销同步后码失效 → valid:false', stB2.body.valid === false, JSON.stringify(stB2.body));

  console.log('── 3. 激活码类型二态化：上报 normal 恒签发 admin（v6.14） ──');
  const codeN = 'ID' + rnd(6);
  await syncCodes(ha.sock, [{ code: codeN, type: 'normal' }]); // 旧客户端类型上报
  const acN = await postJson('/api/activate', { code: codeN, deviceId: PH('1c'), version: MIN_VER });
  check('normal 上报 → 返回 type=admin', acN.body.ok === true && acN.body.type === 'admin', JSON.stringify(acN.body));

  console.log('── 4. 配对码：按硬件稳定 + 设备隔离 ──');
  const h1 = await hostRegister({ deviceId: 'idtest-host-dup', hostToken: 'idtest-host-token-dup' });
  const h2 = await hostRegister({ deviceId: 'idtest-host-dup', hostToken: 'idtest-host-token-dup' });
  check('同一 deviceId 两次注册 → 配对码不变', !!h1.pairCode && h1.pairCode === h2.pairCode,
    JSON.stringify({ first: h1.pairCode, second: h2.pairCode }));
  const h3 = await hostRegister({ deviceId: 'idtest-host-other', hostToken: 'idtest-host-token-other' });
  check('不同 deviceId → 配对码不同', !!h3.pairCode && h3.pairCode !== h2.pairCode,
    JSON.stringify({ a: h2.pairCode, b: h3.pairCode }));

  console.log('── 5. 多电脑管理员：重新激活撤销旧令牌（T6） ──');
  const codeC = 'ID' + rnd(6);
  const HOST_B = { deviceId: 'idtest-host-b', hostToken: 'idtest-host-token-b' };
  const hb = await hostRegister({ ...HOST_B, deviceName: 'e2e身份电脑B', activationCodes: [{ code: codeC, type: 'admin' }] }, true);
  check('电脑B注册成功', !!hb.pairCode, JSON.stringify({ pairCode: hb.pairCode }));
  // 手机 X 先激活电脑 A（用 A 的码），再激活电脑 B
  const codeX1 = 'ID' + rnd(6);
  await syncCodes(ha.sock, [{ code: codeX1, type: 'admin' }]);
  const phoneX = PH('x');
  const ax1 = await postJson('/api/activate', { code: codeX1, deviceId: phoneX, version: MIN_VER });
  check('手机X激活电脑A成功', ax1.body.ok === true && !!ax1.body.deviceToken, JSON.stringify(ax1.body));
  const ax2 = await postJson('/api/activate', { code: codeC, deviceId: phoneX, version: MIN_VER });
  check('手机X再激活电脑B成功（令牌覆盖）', ax2.body.ok === true && !!ax2.body.deviceToken, JSON.stringify(ax2.body));
  const mineOld = await getJson(BASE + `/api/shares/mine?deviceId=${phoneX}&deviceToken=${ax1.body.deviceToken}`);
  check('旧令牌（A）拉取共享 → 401', mineOld.status === 401, mineOld.status + ' ' + JSON.stringify(mineOld.body));
  const mineNew = await getJson(BASE + `/api/shares/mine?deviceId=${phoneX}&deviceToken=${ax2.body.deviceToken}`);
  check('新令牌（B）拉取共享 → 200', mineNew.status === 200 && mineNew.body.ok === true, JSON.stringify(mineNew.body));

  console.log('── 6. 免配对码连接鉴权：旧令牌拒 / 新令牌过（T7） ──');
  const shareToken = 'ID' + rnd(8);
  const s1 = await postJson('/api/shares/sync', {
    deviceId: HOST_A.deviceId, hostToken: HOST_A.hostToken,
    shares: [{ token: shareToken, name: 'e2e身份共享A', folder: 'C:/idtest', perms: ['download'], targetDeviceId: null }],
  });
  check('电脑A公开共享同步成功', s1.body.ok === true, JSON.stringify(s1.body));
  const jb1 = await phoneJoin({ token: shareToken, deviceId: phoneX, deviceToken: ax1.body.deviceToken, joinByShare: true });
  check('旧令牌 join-by-share → 设备令牌无效', jb1.event === 'client:error' && jb1.reason === '设备令牌无效，请重新激活', JSON.stringify(jb1));
  const jb2 = await phoneJoin({ token: shareToken, deviceId: phoneX, deviceToken: ax2.body.deviceToken, joinByShare: true });
  check('新令牌 join-by-share → client:joined', jb2.event === 'client:joined', JSON.stringify(jb2));

  console.log('── 7. 配对码直连不依赖令牌（T8，多电脑管理员保留通道） ──');
  const jc1 = await phoneJoin({ pairCode: ha.pairCode, deviceId: phoneX, version: MIN_VER });
  check('手机X 凭配对码直连电脑A → client:joined（旧令牌下管理员通道仍通）',
    jc1.event === 'client:joined', JSON.stringify(jc1));

  console.log('── 8. 共享访客绑定：共享码即凭证，绑定后免令牌放行（T16） ──');
  const shareTokenC = 'ID' + rnd(8);
  const s2 = await postJson('/api/shares/sync', {
    deviceId: HOST_B.deviceId, hostToken: HOST_B.hostToken,
    shares: [{ token: shareTokenC, name: 'e2e身份共享B', folder: 'C:/idtest-b', perms: ['download'], targetDeviceId: null }],
  });
  check('电脑B公开共享同步成功', s2.body.ok === true, JSON.stringify(s2.body));
  const codeY = 'ID' + rnd(6);
  await syncCodes(hb.sock, [{ code: codeY, type: 'admin' }]);
  const phoneY = PH('y');
  const ay = await postJson('/api/activate', { code: codeY, deviceId: phoneY, version: MIN_VER });
  check('手机Y激活电脑B成功', ay.body.ok === true && !!ay.body.deviceToken, JSON.stringify(ay.body));
  const jy1 = await phoneJoin({ token: shareTokenC, deviceId: phoneY, deviceToken: ay.body.deviceToken, joinByShare: true });
  check('手机Y 带令牌 join-by-share → client:joined（记录绑定）', jy1.event === 'client:joined', JSON.stringify(jy1));
  const jy2 = await phoneJoin({ token: shareTokenC, deviceId: phoneY, deviceToken: '', joinByShare: true });
  check('手机Y 免令牌（绑定放行）join-by-share → client:joined', jy2.event === 'client:joined', JSON.stringify(jy2));
  const jy3 = await phoneJoin({ token: shareTokenC, deviceId: PH('z'), deviceToken: '', joinByShare: true });
  check('未绑定设备免令牌 → 设备令牌无效', jy3.event === 'client:error' && jy3.reason === '设备令牌无效，请重新激活', JSON.stringify(jy3));

  console.log('── 9. 主机令牌伪造防护 / 共享接口鉴权（T13/T14） ──');
  const s3 = await postJson('/api/shares/sync', {
    deviceId: HOST_A.deviceId, hostToken: 'WRONG-TOKEN',
    shares: [{ token: 'XX', name: 'x', folder: 'C:/x', perms: [], targetDeviceId: null }],
  });
  check('假 hostToken sync → 403', s3.status === 403, s3.status + ' ' + JSON.stringify(s3.body));
  const pj1 = await postJson('/api/shares/join', { deviceId: phoneX, deviceToken: 'WRONG-TOKEN', token: shareToken });
  check('假 deviceToken attach → 401', pj1.status === 401, pj1.status + ' ' + JSON.stringify(pj1.body));

  console.log('── 10. 版本门禁（T9） ──');
  const g1 = await postJson('/api/activate', { code: codeN, deviceId: PH('old'), version: '5.5' });
  check('旧版激活 → APP_VERSION_REQUIRED', g1.body.ok === false && g1.body.error === 'APP_VERSION_REQUIRED', JSON.stringify(g1.body));
  const g2 = await phoneJoin({ pairCode: ha.pairCode, deviceId: PH('old'), version: '5.5' });
  check('旧版 join → APP_VERSION_REQUIRED', g2.event === 'client:error' && g2.reason === 'APP_VERSION_REQUIRED', JSON.stringify(g2));

  console.log('── 11. 并发防重放：同码双激活恰一成功（T11） ──');
  const codeP = 'ID' + rnd(6);
  await syncCodes(ha.sock, [{ code: codeP, type: 'admin' }]);
  const [p1, p2] = await Promise.all([
    postJson('/api/activate', { code: codeP, deviceId: PH('p1'), version: MIN_VER }),
    postJson('/api/activate', { code: codeP, deviceId: PH('p2'), version: MIN_VER }),
  ]);
  const okCount = [p1, p2].filter((r) => r.body.ok === true).length;
  check('同码并发激活恰 1 个成功', okCount === 1, JSON.stringify([p1.body, p2.body]));

  console.log('── 12. 后台管理（T12） ──');
  const login = await postJson('/api/admin/login', { username: 'admin', password: process.env.ADMIN_PASSWORD || 'admin123' });
  check('后台登录成功', login.body.ok === true && !!login.body.token,
    JSON.stringify(login.body) + (login.body.ok ? '' : ' （密码已改可设 ADMIN_PASSWORD 环境变量重跑）'));
  if (login.body.ok && login.body.token) {
    const noAuth = await getJson(BASE + '/api/admin/hosts');
    check('未登录访问 hosts → 401', noAuth.status === 401, String(noAuth.status));
    const r = await fetch(BASE + '/api/admin/hosts', { headers: { Authorization: `Bearer ${login.body.token}` } });
    const hostsBody = await r.json();
    check('带 token 访问 hosts → 200', r.status === 200 && hostsBody.ok === true, String(r.status));
    const onlineA = (hostsBody.hosts || []).find((x) => x.deviceId === HOST_A.deviceId);
    check('在线列表包含测试电脑A（在线/版本/配对码）',
      !!onlineA && onlineA.online === true && onlineA.pairCode === ha.pairCode,
      JSON.stringify(onlineA));
  }

  console.log('── 清理 ──');
  // 删除测试共享（全量覆盖置空），关闭模拟电脑端 socket
  await postJson('/api/shares/sync', { deviceId: HOST_A.deviceId, hostToken: HOST_A.hostToken, shares: [] });
  await postJson('/api/shares/sync', { deviceId: HOST_B.deviceId, hostToken: HOST_B.hostToken, shares: [] });
  for (const s of [ha.sock, hb.sock]) { try { s.close(); } catch { /* 已断开 */ } }
  console.log('  已删除测试共享并关闭模拟电脑端（act-devices/host-codes/join-relations 残留 idtest-* 记录由服务器保留）');

  console.log(`\n结果: ${pass} PASS / ${fail} FAIL`);
  process.exit(fail === 0 ? 0 : 1);
})();
