#!/bin/bash
# 等保一级整改部署：ENC_KEY + crontab 备份 + 重启服务（server.js 已替换为新版）
set -e
cd /opt/p2p-app
# 1. 生成 ENC_KEY（如未配置）
if ! grep -q '^export ENC_KEY=' /opt/p2p-app/env.sh 2>/dev/null; then
  KEY=$(openssl rand -hex 32)
  echo "export ENC_KEY=$KEY" >> /opt/p2p-app/env.sh
  echo "[sec] ENC_KEY 已生成并写入 env.sh"
else
  echo "[sec] ENC_KEY 已存在"
fi
chmod +x /opt/p2p-app/backup.sh
# 2. 配置 crontab 每日 02:30 备份（幂等，不重复添加）
( crontab -l 2>/dev/null | grep -v 'p2p-app/backup.sh' ; echo '30 2 * * * /opt/p2p-app/backup.sh >> /var/log/p2p-backup.log 2>&1' ) | crontab -
echo "[sec] crontab 已配置:"
crontab -l | grep backup
# 3. 立即执行一次备份
/opt/p2p-app/backup.sh
ls -la /opt/p2p-backups/ | tail -3
# 4. 重启服务（加载加密逻辑，明文文件自动迁移为密文）
PID=$(pgrep -f 'node server.js' | head -1)
if [ -n "$PID" ]; then kill "$PID"; sleep 1; fi
. ./env.sh
setsid nohup node server.js >> /tmp/p2p-server.log 2>&1 &
sleep 3
echo "[sec] 服务已重启: PID=$(pgrep -f 'node server.js' | head -1)"
echo "[sec] 启动日志:"
tail -5 /tmp/p2p-server.log
