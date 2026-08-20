#!/bin/bash
# 等保一级整改：每日备份敏感数据文件（保留 30 天）
# 定时: crontab 每天 02:30 执行（由部署步骤配置）
SRC=/opt/p2p-app
DEST=/opt/p2p-backups/$(date +%Y%m%d_%H%M%S)
mkdir -p "$DEST"
for f in users.json tokens.json shares.json act-devices.json host-tokens.json host-codes.json join-relations.json licenses.json; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/"
done
# 保留最近 30 天，删除更早的备份目录
find /opt/p2p-backups -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null
echo "[backup] $(date '+%F %T') 备份完成: $DEST ($(ls "$DEST" | wc -l) 个文件)"
