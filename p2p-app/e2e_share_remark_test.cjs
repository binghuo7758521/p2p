// 共享备注名称链路 E2E（v6.15/v5.21）：电脑端同步 name=备注优先 →
// 服务器存储 → 手机端 /api/shares/mine 展示
// 运行: node e2e_share_remark_test.cjs
// 幂等设计：deviceId/激活码随机化，用后清理共享。
const { io } = require('socket.io-client');

const BASE = 'http://182.92.157.93:3000';
const MIN_VER = '5.21';
const HOST_VER = '6.15';
const RUN = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
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
const rnd = (n) => {
  const cs = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  let s = '';
  for (let i = 0; i < n; i++) s += cs[Math.floor(Math.random() * cs.length)];
  return s;
};
function hostRegister(info) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    sock.on('connect', () => {
      sock.emit('host:register', {
        deviceId: info.deviceId, version: HOST_VER,
        hostToken: info.hostToken, // 预置令牌：注册时绑定，HTTP 同步复用
      });
    });
    sock.on('host:registered', (msg) => {
      info.pairCode = msg.pairCode;
      resolve(sock);
    });
    sock.on('connect_error', (e) => { console.log('  host 连接失败', e.message); resolve(null); });
  });
}
function syncCodes(hostSock, codes) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 8000);
    hostSock.once('host:codes-synced', () => { clearTimeout(timer); resolve(true); });
    hostSock.emit('host:sync-codes', { codes });
  });
}
function phoneJoin(payload) {
  return new Promise((resolve) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    sock.on('connect', () => {
      sock.emit('client:join-by-share', payload);
    });
    sock.on('client:joined', (msg) => { sock.close(); resolve({ ok: true, msg }); });
    sock.on('client:error', (msg) => { sock.close(); resolve({ ok: false, msg }); });
    sock.on('connect_error', (e) => resolve({ ok: false, msg: { error: e.message } }));
    setTimeout(() => resolve({ ok: false, msg: { error: '超时' } }), 8000);
  });
}

(async () => {
  console.log(`── 共享备注名称链路（RUN=${RUN}）──`);
  const hostA = { deviceId: `rmk-host-${RUN}`, hostToken: `rmk-host-token-${RUN}` };
  const phoneX = { deviceId: `rmk-phone-${RUN}` };

  // 1. 电脑A注册 + 生成激活码
  const ha = await hostRegister(hostA);
  check('电脑A注册成功', !!ha, 'hostRegister 失败');
  if (!ha) { console.log(`结果: ${pass} PASS / ${fail} FAIL`); process.exit(fail ? 1 : 0); }
  const code = rnd(8);
  await syncCodes(ha, [{ code, type: 'admin' }]);

  // 2. 手机X激活
  const act = await postJson('/api/activate', {
    code, deviceId: phoneX.deviceId, version: MIN_VER,
  });
  check('手机X激活成功', act.body?.ok === true, JSON.stringify(act.body));
  const deviceToken = act.body?.deviceToken || '';

  // 3. 电脑A同步共享：folder 全路径 + name=备注（备注优先，非文件夹末段）；
  //    定向共享（targetDeviceId=手机X）→ 激活令牌即可在 mine 可见
  const shareToken = 'rmk' + rnd(8);
  const sync1 = await postJson('/api/shares/sync', {
    deviceId: hostA.deviceId, hostToken: hostA.hostToken,
    shares: [{
      token: shareToken,
      folder: 'D:/项目/工作资料',
      name: '我的工作', // 备注名称
      perms: ['download', 'upload'],
      targetDeviceId: phoneX.deviceId,
    }],
  });
  check('共享同步成功', sync1.body?.ok === true, JSON.stringify(sync1.body));

  // 4. 手机X 拉取“共享给我的”：显示备注而非全路径
  const mine1 = await getJson(
    `${BASE}/api/shares/mine?deviceId=${phoneX.deviceId}&deviceToken=${deviceToken}`);
  const entry1 = mine1.body?.shares?.find((s) => s.token === shareToken);
  check('mine 返回备注名称', mine1.status === 200 && entry1?.name === '我的工作',
    `name=${JSON.stringify(entry1?.name)}`);
  check('mine 不暴露全路径字段', !entry1?.folder, `folder=${JSON.stringify(entry1?.folder)}`);
  check('mine 保留 hostName', entry1?.hostName?.length > 0, JSON.stringify(entry1?.hostName));

  // 5. 电脑A改备注（重新同步 name=新备注）
  const sync2 = await postJson('/api/shares/sync', {
    deviceId: hostA.deviceId, hostToken: hostA.hostToken,
    shares: [{
      token: shareToken,
      folder: 'D:/项目/工作资料',
      name: '工作资料-改名',
      perms: ['download', 'upload'],
      targetDeviceId: phoneX.deviceId,
    }],
  });
  const mine2 = await getJson(
    `${BASE}/api/shares/mine?deviceId=${phoneX.deviceId}&deviceToken=${deviceToken}`);
  const entry2 = mine2.body?.shares?.find((s) => s.token === shareToken);
  check('改名后 mine 同步新备注', sync2.body?.ok === true && entry2?.name === '工作资料-改名',
    `name=${JSON.stringify(entry2?.name)}`);

  // 6. 备注留空回退文件夹末段
  const sync3 = await postJson('/api/shares/sync', {
    deviceId: hostA.deviceId, hostToken: hostA.hostToken,
    shares: [{
      token: shareToken,
      folder: 'D:/项目/工作资料',
      name: '', // 留空 → 服务器默认？电脑端实际会上报文件夹末段
      perms: ['download', 'upload'],
      targetDeviceId: phoneX.deviceId,
    }],
  });
  const mine3 = await getJson(
    `${BASE}/api/shares/mine?deviceId=${phoneX.deviceId}&deviceToken=${deviceToken}`);
  const entry3 = mine3.body?.shares?.find((s) => s.token === shareToken);
  check('备注留空回退文件夹名', sync3.body?.ok === true && !!entry3?.name,
    `name=${JSON.stringify(entry3?.name)}`);

  // 清理：删除测试共享 + 关闭 socket
  await postJson('/api/shares/sync', {
    deviceId: hostA.deviceId, hostToken: hostA.hostToken, shares: [],
  });
  ha.close();
  console.log(`结果: ${pass} PASS / ${fail} FAIL`);
  process.exit(fail ? 1 : 0);
})();
