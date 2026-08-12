#!/bin/bash
# 部署脚本：重启 node server.js（由本地 scp + ssh bash 调用，避免 PowerShell 变量展开问题）
for PID in $(pgrep -f 'node server.js'); do
  kill "$PID" 2>/dev/null
done
sleep 1
cd /opt/p2p-app || exit 1
setsid nohup node server.js > /tmp/p2p-server.log 2>&1 &
sleep 3
echo "--- 新进程 ---"
pgrep -f 'node server.js' | head -3
echo "--- 版本接口 ---"
curl -s http://127.0.0.1:3000/version
echo ""
