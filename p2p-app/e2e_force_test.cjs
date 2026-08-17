// 强制升级机制 E2E 验证（v2.9/6.10/5.14 无限大盘改名 + 手机端强制升级 + 单架构瘦身 + 扫码加入持久化）
// 运行: node e2e_force_test.cjs
const { io } = require('socket.io-client');

const BASE = 'http://182.92.157.93:3000';
let pass = 0, fail = 0;

function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name} ${extra}`); }
}

async function getJson(url) {
  const r = await fetch(url);
  return { status: r.status, body: await r.json() };
}

async function postJson(path, body) {
  const r = await fetch(BASE + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: r.status, body: await r.json() };
}

function socketTest(name, payload, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    const t = setTimeout(() => { sock.close(); resolve({ reason: 'TIMEOUT', raw: null }); }, timeoutMs);
    sock.on('connect', () => sock.emit('client:join', payload));
    sock.on('client:error', (d) => {
      clearTimeout(t);
      sock.close();
      resolve({ reason: d?.reason, raw: d });
    });
    sock.on('connect_error', (e) => {
      clearTimeout(t);
      resolve({ reason: 'CONNECT_ERROR', raw: String(e) });
    });
  });
}

// 模拟电脑端注册（v2.8 扫码加入用例）：返回 host:registered 回执；
// holdOpen=true 时保持 socket 在线（扫码加入需主机在线才能成功）
function hostRegister(info, holdOpen = false, timeoutMs = 8000) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    const t = setTimeout(() => { sock.close(); resolve({ pairCode: null, error: 'TIMEOUT' }); }, timeoutMs);
    sock.on('connect', () => sock.emit('host:register', {
      deviceName: info.deviceName || 'e2e电脑', desktop: true, version: '6.10',
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

// 模拟手机端扫码加入（client:join-by-share）：成功回执为 client:joined
function joinByShare(token, deviceId, deviceToken, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    const t = setTimeout(() => { sock.close(); resolve({ event: 'TIMEOUT' }); }, timeoutMs);
    sock.on('connect', () => sock.emit('client:join-by-share', {
      token, deviceId, deviceToken, version: '5.9', deviceName: 'e2e扫码手机',
    }));
    sock.on('client:joined', () => { clearTimeout(t); sock.close(); resolve({ event: 'client:joined' }); });
    sock.on('client:error', (d) => { clearTimeout(t); sock.close(); resolve({ event: 'client:error', reason: d?.reason }); });
    sock.on('connect_error', (e) => { clearTimeout(t); resolve({ event: 'CONNECT_ERROR', raw: String(e) }); });
  });
}

(async () => {
  console.log('── 1. 版本核对 ──');
  const v = await getJson(BASE + '/version');
  check('server=2.9 desktop=6.10 android=5.14',
    v.body.server === '2.9' && v.body.desktop === '6.10' && v.body.android === '5.14',
    JSON.stringify(v.body));

  console.log('── 2. update-check 强制标记 ──');
  const old = await getJson(BASE + '/update-check?platform=android&version=5.5');
  check('旧版 5.5 → force=true', old.body.force === true, JSON.stringify(old.body));
  check('旧版 5.5 → needUpdate=true', old.body.needUpdate === true);
  check('旧版 5.5 → 升级包就绪 url 非空', !!old.body.url);
  check('升级说明含手动下载指引 manual/apk', (old.body.notes || '').includes('manual/apk'), old.body.notes);

  const cur = await getJson(BASE + '/update-check?platform=android&version=5.14');
  check('新版 5.14 → force=false', cur.body.force === false, JSON.stringify(cur.body));
  check('新版 5.14 → needUpdate=false', cur.body.needUpdate === false);

  const desOld = await getJson(BASE + '/update-check?platform=desktop&version=6.2');
  check('电脑端 6.2 → needUpdate=true', desOld.body.needUpdate === true);
  check('电脑端 6.2 → md5 非空', !!desOld.body.md5);
  const desCur = await getJson(BASE + '/update-check?platform=desktop&version=6.10');
  check('电脑端 6.10 → needUpdate=false', desCur.body.needUpdate === false);

  console.log('── 3. /api/activate 版本拦截 ──');
  const a1 = await postJson('/api/activate', { version: '5.5', code: 'AAAAAAAA', deviceId: 'force-test-1' });
  check('旧版 5.5 激活被拒 → APP_VERSION_REQUIRED',
    a1.body.ok === false && a1.body.error === 'APP_VERSION_REQUIRED', JSON.stringify(a1.body));
  const a2 = await postJson('/api/activate', { version: '5.14', code: 'BAD!!!!', deviceId: 'force-test-2' });
  check('新版 5.14 走正常逻辑（码格式错误）',
    a2.body.ok === false && a2.body.error === '激活码格式不正确', JSON.stringify(a2.body));
  const a3 = await postJson('/api/activate', { code: 'AAAAAAAA', deviceId: 'force-test-3' });
  check('不带 version 视为旧版拒绝',
    a3.body.ok === false && a3.body.error === 'APP_VERSION_REQUIRED', JSON.stringify(a3.body));

  console.log('── 4. 信令 join 版本拦截 ──');
  const j1 = await socketTest('j1', { pairCode: 'ABCDEFGHIJ', deviceName: '旧版测试', version: '5.5', deviceId: 'force-test-4' });
  check('旧版 5.5 join 被拒 → APP_VERSION_REQUIRED',
    j1.reason === 'APP_VERSION_REQUIRED', JSON.stringify(j1));
  const j2 = await socketTest('j2', { pairCode: 'ABCDEFGHIJ', deviceName: '新版测试', version: '5.14', deviceId: 'force-test-5' });
  check('新版 5.14 join 走正常逻辑（无效配对码）',
    j2.reason === '配对码无效', JSON.stringify(j2));
  const j3 = await socketTest('j3', { pairCode: 'ABCDEFGHIJ', deviceName: '无版本测试', deviceId: 'force-test-6' });
  check('不带 version join 被拒 → APP_VERSION_REQUIRED',
    j3.reason === 'APP_VERSION_REQUIRED', JSON.stringify(j3));

  console.log('── 5. 下载链（302 → OSS）──');
  const z = await fetch(BASE + '/downloads/p2p_desktop.zip', { redirect: 'manual' });
  check('zip 302 重定向', z.status === 302 && (z.headers.get('location') || '').includes('aliyuncs'), String(z.status) + ' ' + z.headers.get('location'));
  const a = await fetch(BASE + '/downloads/app-release.apk', { redirect: 'manual' });
  check('apk 302 重定向（无后缀对象）',
    a.status === 302 && (a.headers.get('location') || '').includes('app-release'), String(a.status) + ' ' + a.headers.get('location'));

  console.log('── 6. 已删接口 404 抽查 ──');
  for (const p of ['/api/register', '/api/login', '/api/send-sms']) {
    const r = await fetch(BASE + p, { method: 'POST' });
    check(`${p} → 404`, r.status === 404, String(r.status));
  }

  console.log('── 7. 扫码加入持久化到“共享给我的”（v2.9）──');
  // 幂等设计：token/激活码随机化，重复运行不依赖上次状态（激活码一次性、绑定会持久化）
  const rnd = (n) => Array.from({ length: n },
      () => 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[Math.floor(Math.random() * 32)]).join('');
  const scanToken = 'E2E' + rnd(8);
  const scanCode = 'E2E' + rnd(5);
  const HOST_SCAN = { deviceId: 'e2e-host-scan', hostToken: 'e2e-host-token-scan' };
  const h = await hostRegister({ ...HOST_SCAN, deviceName: 'e2e扫码电脑', activationCodes: [{ code: scanCode, type: 'normal' }] }, true);
  check('电脑端注册成功', !!h.pairCode, JSON.stringify({ pairCode: h.pairCode }));
  const s1 = await postJson('/api/shares/sync', {
    deviceId: HOST_SCAN.deviceId, hostToken: HOST_SCAN.hostToken,
    shares: [{ token: scanToken, name: 'e2e扫码共享', folder: 'C:/e2e-scan', perms: ['download'], targetDeviceId: null }],
  });
  check('公开共享同步成功', s1.body.ok === true, JSON.stringify(s1.body));
  const ac = await postJson('/api/activate', { code: scanCode, deviceId: 'e2e-phone-scan', version: '5.14' });
  check('手机激活成功（拿到设备令牌）', ac.body.ok === true && !!ac.body.deviceToken, JSON.stringify(ac.body));
  const devTok = ac.body.deviceToken;
  const mine1 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-scan&deviceToken=${devTok}`);
  check('扫码前列表不含该共享',
    !mine1.body.shares.some((x) => x.token === scanToken), JSON.stringify(mine1.body));
  const jb = await joinByShare(scanToken, 'e2e-phone-scan', devTok);
  check('扫码加入成功（client:joined）', jb.event === 'client:joined', JSON.stringify(jb));
  const mine2 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-scan&deviceToken=${devTok}`);
  check('扫码后出现在“共享给我的”',
    mine2.body.shares.some((x) => x.token === scanToken && x.name === 'e2e扫码共享'),
    JSON.stringify(mine2.body));
  const s2 = await postJson('/api/shares/sync', {
    deviceId: HOST_SCAN.deviceId, hostToken: HOST_SCAN.hostToken, shares: [],
  });
  check('电脑端删除共享（全量覆盖）', s2.body.ok === true, JSON.stringify(s2.body));
  const mine3 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-scan&deviceToken=${devTok}`);
  check('删除后列表自动消失',
    !mine3.body.shares.some((x) => x.token === scanToken), JSON.stringify(mine3.body));
  h.sock.close();  // 关闭模拟电脑端

  console.log('── 8. 扫码两条真实路径绑定（v2.9）──');
  // 路径1：未连接扫码 → client:join（配对码 + shareToken，手机端扫码真实路径）
  const joinToken = 'E2E' + rnd(8);
  const joinCode = 'E2E' + rnd(5);
  const HOST_J = { deviceId: 'e2e-host-join', hostToken: 'e2e-host-token-join' };
  const h2 = await hostRegister({ ...HOST_J, deviceName: 'e2e扫码电脑2', activationCodes: [{ code: joinCode, type: 'normal' }] }, true);
  check('电脑端注册成功(路径1)', !!h2.pairCode, JSON.stringify({ pairCode: h2.pairCode }));
  const sj1 = await postJson('/api/shares/sync', {
    deviceId: HOST_J.deviceId, hostToken: HOST_J.hostToken,
    shares: [{ token: joinToken, name: 'e2e扫码共享2', folder: 'C:/e2e-join', perms: ['download'], targetDeviceId: null }],
  });
  check('公开共享同步成功(路径1)', sj1.body.ok === true, JSON.stringify(sj1.body));
  const ac2 = await postJson('/api/activate', { code: joinCode, deviceId: 'e2e-phone-join', version: '5.14' });
  check('手机激活成功(路径1)', ac2.body.ok === true && !!ac2.body.deviceToken, JSON.stringify(ac2.body));
  const devTok2 = ac2.body.deviceToken;
  const mj0 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-join&deviceToken=${devTok2}`);
  check('路径1 扫码前不可见', !mj0.body.shares.some((x) => x.token === joinToken), JSON.stringify(mj0.body));
  const jj = await socketTest('jj', { pairCode: h2.pairCode, deviceName: 'e2e扫码手机2', version: '5.12', deviceId: 'e2e-phone-join', shareToken: joinToken });
  check('client:join+shareToken 配对成功', jj.reason === 'TIMEOUT', JSON.stringify(jj));
  const mj1 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-join&deviceToken=${devTok2}`);
  check('路径1 扫码后出现在“共享给我的”', mj1.body.shares.some((x) => x.token === joinToken), JSON.stringify(mj1.body));
  // 路径2：已连接扫码 → attachShare → POST /api/shares/join 上报绑定
  const joinTokenB = 'E2E' + rnd(8);
  const sj2 = await postJson('/api/shares/sync', {
    deviceId: HOST_J.deviceId, hostToken: HOST_J.hostToken,
    shares: [{ token: joinTokenB, name: 'e2e扫码共享3', folder: 'C:/e2e-attach', perms: ['download'], targetDeviceId: null }],
  });
  check('公开共享同步成功(路径2)', sj2.body.ok === true, JSON.stringify(sj2.body));
  const mj2 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-join&deviceToken=${devTok2}`);
  check('路径2 attach 前不可见', !mj2.body.shares.some((x) => x.token === joinTokenB), JSON.stringify(mj2.body));
  const pj1 = await postJson('/api/shares/join', { deviceId: 'e2e-phone-join', deviceToken: devTok2, token: joinTokenB });
  check('attach 上报绑定成功', pj1.body.ok === true, JSON.stringify(pj1.body));
  const pj2 = await postJson('/api/shares/join', { deviceId: 'e2e-phone-join', deviceToken: 'WRONG-TOKEN', token: joinTokenB });
  check('attach 上报无效令牌被拒(401)', pj2.status === 401, String(pj2.status));
  const mj3 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-join&deviceToken=${devTok2}`);
  check('路径2 绑定后出现在“共享给我的”', mj3.body.shares.some((x) => x.token === joinTokenB), JSON.stringify(mj3.body));
  // 清理：电脑端删除全部共享，两条路径自然消失
  const sj3 = await postJson('/api/shares/sync', { deviceId: HOST_J.deviceId, hostToken: HOST_J.hostToken, shares: [] });
  check('电脑端删除共享(路径2)', sj3.body.ok === true, JSON.stringify(sj3.body));
  const mj4 = await getJson(BASE + `/api/shares/mine?deviceId=e2e-phone-join&deviceToken=${devTok2}`);
  check('删除后路径2列表消失', !mj4.body.shares.some((x) => x.token === joinTokenB), JSON.stringify(mj4.body));
  h2.sock.close();  // 关闭模拟电脑端

  console.log(`\n结果: ${pass} PASS / ${fail} FAIL`);
  process.exit(fail === 0 ? 0 : 1);
})();
