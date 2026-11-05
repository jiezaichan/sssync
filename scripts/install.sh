#!/bin/bash
# 编译 sssync 并安装到本机和对面那台的 /Applications（Finder 里的「应用程序」），装完重新打开。
# 旧版本装在 ~/Applications，顺手删掉，免得系统里有两个 sssync。
#
#   scripts/install.sh            本机 + 对面都装
#   scripts/install.sh --local    只装本机
#
# 对面那台按本机型号自动选：家里（Mac14,5）→ ssh mini，公司 → ssh home。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="sssync.app"
DEST="/Applications/$APP_NAME"
OLD="Applications/$APP_NAME"   # 相对家目录的旧位置
LOCAL_ONLY=0
[[ "${1:-}" == "--local" ]] && LOCAL_ONLY=1

cd "$ROOT"
echo "==> 生成工程"
xcodegen generate -q

echo "==> 编译（Release，开发者证书签名）"
xcodebuild -project sssync.xcodeproj -scheme sssync -configuration Release \
  -derivedDataPath build build -quiet
BUILT="$ROOT/build/Build/Products/Release/$APP_NAME"
codesign --verify --deep --strict "$BUILT"
TEAM="$(codesign -dv "$BUILT" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$TEAM" != "96BTTXKZ9W" ]]; then
  echo "签名团队不对（${TEAM}），应为 96BTTXKZ9W" >&2
  exit 1
fi
echo "    签名团队 $TEAM"

restart_local() {
  osascript -e 'tell application id "com.jiezaichan.sssync" to quit' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$HOME/$OLD"
  rm -rf "$DEST"
  cp -R "$BUILT" "$DEST"
  open "$DEST"
}

echo "==> 安装到本机 $DEST"
restart_local

if [[ $LOCAL_ONLY -eq 0 ]]; then
  if [[ "$(sysctl -n hw.model)" == "Mac14,5" ]]; then PEER=mini; else PEER=home; fi
  echo "==> 安装到对面（ssh ${PEER}）"
  ssh "$PEER" "osascript -e 'tell application id \"com.jiezaichan.sssync\" to quit' >/dev/null 2>&1 || true; sleep 1; rm -rf ~/$OLD"
  /usr/bin/rsync -a --delete "$BUILT/" "$PEER:$DEST/"
  ssh "$PEER" "open $DEST"
fi

echo "==> 完成"
