#!/bin/bash
# TURN 中转带宽限速（降速共享模式）：relay 端口(49152-49215) 双向总带宽 2MB/s
# - 并发不限：任何数量会话都可建立，总带宽 2MB/s 内由 fq_codel 公平分摊
# - 其他流量（SSH/信令/升级下载）不受影响（默认类 100mbit 不限制）
# 用法: bash turn_ratelimit.sh apply|clear|status
RATE=16mbit        # 2MB/s = 2097152 B/s（relay 流量总带宽）
OTHER=100mbit      # 其他流量上限（足够大 = 不限制）
RELAY=0xC000       # 49152（端口段 49152-49215，掩码 0xFFC0，覆盖 coturn 49160-49200）
MASK=0xFFC0
UDP=17             # ip protocol udp

del_ingress() {
  tc qdisc del dev eth0 ingress 2>/dev/null || true
}

apply() {
  # ── 下行（服务器→客户端）：eth0 egress ──
  tc qdisc del dev eth0 root 2>/dev/null || true
  tc qdisc add dev eth0 root handle 1: htb default 10
  tc class add dev eth0 parent 1: classid 1:1 htb rate $OTHER ceil $OTHER
  tc class add dev eth0 parent 1:1 classid 1:10 htb rate $OTHER ceil $OTHER
  # relay 总带宽类：多会话共享，fq_codel 按流公平分摊
  tc class add dev eth0 parent 1:1 classid 1:30 htb rate $RATE ceil $RATE
  tc qdisc add dev eth0 parent 1:30 handle 30: fq_codel
  tc filter add dev eth0 parent 1:0 protocol ip prio 1 u32 \
    match ip protocol $UDP 0xff match ip sport $RELAY $MASK flowid 1:30

  # ── 上行（客户端→服务器）：ingress → ifb0 ──
  modprobe ifb 2>/dev/null || true
  ip link add ifb0 type ifb 2>/dev/null || true
  ip link set ifb0 up
  del_ingress
  tc qdisc add dev eth0 handle ffff: ingress
  tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 \
    match ip protocol $UDP 0xff match ip dport $RELAY $MASK \
    action mirred egress redirect dev ifb0
  tc qdisc del dev ifb0 root 2>/dev/null || true
  tc qdisc add dev ifb0 root handle 1: htb default 30
  tc class add dev ifb0 parent 1: classid 1:1 htb rate $OTHER ceil $OTHER
  # ifb0 上全是 relay 数据：默认类即限速类
  tc class add dev ifb0 parent 1:1 classid 1:30 htb rate $RATE ceil $RATE
  tc qdisc add dev ifb0 parent 1:30 handle 30: fq_codel

  echo 'TURN 限速已应用: relay 总带宽 2MB/s（降速共享，并发不限）'
}

clear() {
  tc qdisc del dev eth0 root 2>/dev/null || true
  tc qdisc del dev ifb0 root 2>/dev/null || true
  del_ingress
  echo 'TURN 限速已清除'
}

status() {
  echo '── 下行 eth0 relay 类(1:30) ──'
  tc -s class show dev eth0 | grep -A3 'class htb 1:30' || echo '未应用'
  echo '── 上行 ifb0 relay 类(1:30) ──'
  tc -s class show dev ifb0 | grep -A3 'class htb 1:30' || echo '未应用'
}

case "$1" in
  apply) apply ;;
  clear) clear ;;
  status) status ;;
  *) echo "用法: $0 apply|clear|status" ;;
esac
