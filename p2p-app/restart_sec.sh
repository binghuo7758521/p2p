#!/bin/bash
# 等保整改：重启 server.js（加载加密逻辑）
cd /opt/p2p-app
PID=$(pgrep -f 'node server.js' | head -1)
[ -n "$PID" ] && kill "$PID"
sleep 1
. ./env.sh
setsid nohup node server.js >> /tmp/p2p-server.log 2>&1 &
sleep 3
echo "restarted PID=$(pgrep -f 'node server.js' | head -1)"
tail -8 /tmp/p2p-server.log
