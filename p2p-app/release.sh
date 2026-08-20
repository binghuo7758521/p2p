#!/bin/bash
# 一键发布升级包：OSS 同步 → 版本号更新 → 重启服务 → 全链路验证
# 用法: bash release.sh <desktop|android> <新版本号> [旧版本号] [urgent]
# 例:   bash release.sh desktop 6.17 6.16
#       bash release.sh desktop 6.23 6.22 urgent   # 重要升级：设置紧急线，客户端立即弹窗高频检查
#       bash release.sh android 5.22 5.21
# 前置: 升级包已 scp 到 /opt/p2p-app/downloads/（desktop: p2p_desktop.zip / android: app-release.apk）
# 说明: 第 4 参数 urgent 仅 desktop 有效——写入 upgrade-config.json 设置重要升级线=新版本
#       （update-check 返回 urgent=true，客户端立即弹“重要升级”窗并每 5 分钟高频检查）；
#       不带则清空紧急线（普通升级）。与管理后台 /api/admin/upgrade 同一数据源
set -e
cd /opt/p2p-app || exit 1

PLATFORM=$1
NEW_VER=$2
OLD_VER=$3
URGENT=$4
if [ -z "$PLATFORM" ] || [ -z "$NEW_VER" ]; then
  echo "用法: release.sh <desktop|android> <新版本> [旧版本] [urgent]"
  exit 1
fi

if [ "$PLATFORM" = "desktop" ]; then
  FILE=downloads/p2p_desktop.zip
  OBJ=p2p_desktop.zip
  CONST=DESKTOP_VERSION
elif [ "$PLATFORM" = "android" ]; then
  FILE=downloads/app-release.apk
  OBJ=app-release
  CONST=ANDROID_VERSION
else
  echo "platform 必须是 desktop 或 android"
  exit 1
fi

echo "== 1/5 检查升级包 =="
[ -f "$FILE" ] || { echo "缺少 $FILE，请先 scp 升级包"; exit 1; }
SIZE=$(stat -c %s "$FILE")
MD5=$(md5sum "$FILE" | awk '{print $1}')
echo "  $FILE size=$SIZE md5=$MD5"

echo "== 2/5 OSS 同步 =="
python3 oss_upload.py || { echo "OSS 上传失败"; exit 1; }

echo "== 3/5 版本号更新 $CONST=$NEW_VER =="
grep -q "^const $CONST *=" server.js || { echo "server.js 中找不到 $CONST"; exit 1; }
# 锚定行首 const，避免误匹配 MIN_ANDROID_VERSION（含 ANDROID_VERSION 子串）
sed -i "s/^const $CONST *= *'[^']*'/const $CONST = '$NEW_VER'/" server.js
grep "^const $CONST" server.js

# 重要升级线（v2.16+）：写入 upgrade-config.json（与管理后台运行时同一数据源）
# urgent 参数设置紧急线=新版本（客户端立即弹窗高频检查）；不带则清空（普通升级）
# v2.17+：保留已有其他字段（最低支持版本等），仅更新重要升级线，避免发布清掉管理端配置
if [ "$PLATFORM" = "desktop" ]; then
  if [ "$URGENT" = "urgent" ]; then
    node -e "const fs=require('fs');let c={};try{c=JSON.parse(fs.readFileSync('upgrade-config.json','utf8'))}catch(e){};c.desktopUrgentVersion='$NEW_VER';fs.writeFileSync('upgrade-config.json',JSON.stringify(c,null,2));console.log('  重要升级: 紧急线=v$NEW_VER（客户端将立即收到提示）');console.log(fs.readFileSync('upgrade-config.json','utf8'))"
  else
    node -e "const fs=require('fs');let c={};try{c=JSON.parse(fs.readFileSync('upgrade-config.json','utf8'))}catch(e){};c.desktopUrgentVersion=null;fs.writeFileSync('upgrade-config.json',JSON.stringify(c,null,2));console.log('  普通升级: 重要升级线已清空');console.log(fs.readFileSync('upgrade-config.json','utf8'))"
  fi
fi

echo "== 4/5 重启服务 =="
PID=$(pgrep -f 'node server.js' | head -1)
[ -n "$PID" ] && kill "$PID"
sleep 2
. ./env.sh
setsid nohup node server.js >> /tmp/p2p-server.log 2>&1 &
sleep 3
NEW_PID=$(pgrep -f 'node server.js' | head -1)
echo "  新 PID=$NEW_PID"
[ -n "$NEW_PID" ] || { echo "服务启动失败"; exit 1; }

echo "== 5/5 全链路验证 =="
V=$(curl -s http://127.0.0.1:3000/version)
echo "  /version: $V"
echo "$V" | grep -q "\"$PLATFORM\":\"$NEW_VER\"" || { echo "版本未生效"; exit 1; }

if [ -n "$OLD_VER" ]; then
  R=$(curl -s "http://127.0.0.1:3000/update-check?platform=$PLATFORM&version=$OLD_VER")
  echo "  旧版检查: $R"
  echo "$R" | grep -q '"needUpdate":true' || { echo "旧版本未提示升级"; exit 1; }
  echo "$R" | grep -qi "\"md5\":\"$MD5\"" || { echo "接口 md5 与升级包不一致"; exit 1; }
fi

R=$(curl -s "http://127.0.0.1:3000/update-check?platform=$PLATFORM&version=$NEW_VER")
echo "  新版检查: $R"
echo "$R" | grep -q '"needUpdate":false' || { echo "新版本判定异常"; exit 1; }

TMP=/tmp/rel_test_$PLATFORM
rm -f "$TMP"
curl -sL "http://127.0.0.1:3000/downloads/$OBJ" -o "$TMP"
DL_MD5=$(md5sum "$TMP" | awk '{print $1}')
rm -f "$TMP"
echo "  包 md5=$MD5 下载实测 md5=$DL_MD5"
[ "$MD5" = "$DL_MD5" ] || { echo "下载内容与升级包不一致（OSS 未同步？）"; exit 1; }

echo "RESULT: PASS（$PLATFORM v$NEW_VER 发布完成）"
