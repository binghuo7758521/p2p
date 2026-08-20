// 管理员手机端远程确认电脑端升级 E2E 验证（v2.20/6.27/5.42）
// 运行: node e2e_admin_upgrade_test.cjs
// 链路: host 注册(旧版) → admin 激活+join（v2.20+ 补推）→ host 重连触发推送 →
//       admin 收到 upgrade:desktop-notify → confirm → host 收到 upgrade:confirmed →
//       host 上报失败 → admin 收到结果回执 → 非管理员 confirm 被拒
const { io } = require('socket.io-client');

const BASE = 'http://182.92.157.93:3000';
const SUFFIX = Math.random().toString(36).slice(2, 8);
const HOST_DID = 'e2e-host-' + SUFFIX;
const ADMIN_DID = 'e2e-admin-' + SUFFIX;
const GUEST_DID = 'e2e-guest-' + SUFFIX;
const ACT_CODE = 'E2EADMIN' + SUFFIX.toUpperCase().slice(0, 3);

let pass = 0, fail = 0;
function check(name, cond, extra = '') {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name} ${extra}`); }
}

function connect(timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const sock = io(BASE, { transports: ['websocket'], reconnection: false });
    const t = setTimeout(() => reject(new Error('连接超时')), timeoutMs);
    sock.on('connect', () => { clearTimeout(t); resolve(sock); });
    sock.on('connect_error', (e) => { clearTimeout(t); reject(e); });
  });
}

function once(sock, evt, timeoutMs = 8000) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`等待 ${evt} 超时`)), timeoutMs);
    sock.once(evt, (d) => { clearTimeout(t); resolve(d); });
  });
}

async function postJson(path, body) {
  const r = await fetch(BASE + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

(async () => {
  console.log(`== 管理员手机端远程确认电脑端升级 E2E（${SUFFIX}）==\n`);

  // 1. 电脑端注册（v6.25 落后于最新 v6.27），携带管理员激活码
  const host = await connect();
  host.on('host:registered', () => {});
  host.on('host:client-joined', () => {});
  const notifyP = once(host, 'upgrade:notify');
  host.emit('host:register', {
    deviceName: 'e2e升级测试电脑',
    desktop: true,
    version: '6.25',
    deviceId: HOST_DID,
    hostToken: 'e2e-host-token-' + SUFFIX,
    activationCodes: [{ code: ACT_CODE }],
  });
  const reg = await once(host, 'host:registered');
  const pairCode = reg.pairCode;
  check('电脑端注册成功，配对码=' + pairCode, !!pairCode);
  const nf = await notifyP;
  check('电脑端收到 upgrade:notify（6.25 → 6.27）', nf?.latest === '6.27');

  // 2. 管理员手机端激活（type=admin）
  const act = await postJson('/api/activate', {
    code: ACT_CODE,
    deviceId: ADMIN_DID,
    version: '5.42',
  });
  check('管理员激活成功 type=admin', act.ok === true && act.type === 'admin' && act.pairCode === pairCode,
      JSON.stringify(act));

  // 3. 管理员手机端 join（此时 host 在线）→ v2.20+ 配对成功即补推升级提示
  const admin = await connect();
  const adminJoined = once(admin, 'client:joined');
  const dn1P = once(admin, 'upgrade:desktop-notify');
  admin.emit('client:join', {
    pairCode,
    deviceId: ADMIN_DID,
    deviceName: 'e2e管理员手机',
    version: '5.42',
  });
  await adminJoined;
  check('管理员手机端配对成功', true);
  // v2.20+：host 先在线、admin 后上线时，join 成功即补推（此前收不到）
  const dn1 = await dn1P;
  check('admin 后上线收到补推升级提示（v2.20 补推）',
      dn1?.latest === '6.27' && dn1?.current === '6.25', JSON.stringify(dn1));
  check('补推提示包含电脑端名称', dn1?.hostName === 'e2e升级测试电脑');

  // 4. 电脑端重连（触发服务器注册时推送管理员手机端）
  host.close();
  await new Promise((r) => setTimeout(r, 500));
  const host2 = await connect();
  host2.on('upgrade:confirmed', () => {});
  const notify2P = once(host2, 'upgrade:notify');
  host2.emit('host:register', {
    deviceName: 'e2e升级测试电脑',
    desktop: true,
    version: '6.25',
    deviceId: HOST_DID,
    hostToken: 'e2e-host-token-' + SUFFIX,
    activationCodes: [],
  });
  await once(host2, 'host:registered');
  await notify2P;

  // 5. 管理员手机端再次收到电脑端升级提示（host 重连触发注册时推送）
  const dn = await once(admin, 'upgrade:desktop-notify');
  check('管理员手机端收到电脑端升级提示', dn?.latest === '6.27' && dn?.current === '6.25',
      JSON.stringify(dn));
  check('提示包含电脑端名称', dn?.hostName === 'e2e升级测试电脑');
  check('非重要升级 urgent=false', dn?.urgent === false);

  // 6. 管理员确认升级 → 电脑端收到 upgrade:confirmed + 手机端收到回执
  const confirmedP = once(host2, 'upgrade:confirmed');
  const resultP = once(admin, 'upgrade:desktop-result');
  admin.emit('upgrade:confirm');
  const cf = await confirmedP;
  check('电脑端收到 upgrade:confirmed（latest=6.27）', cf?.latest === '6.27');
  const rs = await resultP;
  check('管理员手机端收到确认回执 ok=true', rs?.ok === true, JSON.stringify(rs));

  // 7. 电脑端上报升级失败 → 服务器转发给管理员手机端
  host2.emit('upgrade:desktop-result', { ok: false, error: 'E2E模拟升级失败' });
  const failRs = await once(admin, 'upgrade:desktop-result');
  check('升级失败已转发给管理员手机端', failRs?.ok === false && failRs?.error === 'E2E模拟升级失败',
      JSON.stringify(failRs));

  // 8. 非管理员手机端（未激活设备）confirm 被拒
  const guest = await connect();
  guest.emit('client:join', {
    pairCode,
    deviceId: GUEST_DID,
    deviceName: 'e2e普通手机',
    version: '5.42',
  });
  await once(guest, 'client:joined');
  const guestResultP = once(guest, 'upgrade:desktop-result');
  guest.emit('upgrade:confirm');
  const grs = await guestResultP;
  check('非管理员确认被拒（无权限）', grs?.ok === false && /无权限/.test(grs?.error || ''),
      JSON.stringify(grs));

  // 清理
  host2.close();
  admin.close();
  guest.close();

  console.log(`\n结果: ${pass} PASS / ${fail} FAIL`);
  process.exit(fail > 0 ? 1 : 0);
})().catch((e) => {
  console.error('测试异常:', e.message);
  process.exit(2);
});
