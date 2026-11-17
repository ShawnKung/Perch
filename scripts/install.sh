#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
SOURCE="$ROOT/build/Perch.app"
TARGET="/Applications/Perch.app"
log() { printf '[%s] [%s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2"; }

codesign --verify --deep --strict "$SOURCE"
if [[ -L "$TARGET" || ( -e "$TARGET" && ! -d "$TARGET" ) ]]; then
  log "停止" "$TARGET 不是普通应用目录"
  exit 1
fi
if [[ -d "$TARGET" ]]; then
  if ! cmp -s "$SOURCE/Contents/MacOS/PerchVault" "$TARGET/Contents/MacOS/PerchVault"; then
    log "停止" "密码组件内容发生变化；请先确认签名与钥匙串迁移方案，再手动安装"
    exit 1
  fi
  if [[ -f "$TARGET/Contents/MacOS/PerchAIKeys" ]] && ! cmp -s "$SOURCE/Contents/MacOS/PerchAIKeys" "$TARGET/Contents/MacOS/PerchAIKeys"; then
    log "停止" "AI 钥匙串组件内容发生变化；请先验证 Key 迁移方案，再手动安装"
    exit 1
  fi
fi

# Stage on the destination volume so replacing the bundle uses rename.
STAGE="$(mktemp -d /Applications/.perch-install.XXXXXX)"
COMMITTED=0
INSTALLED=0
cleanup() {
  local status=$?
  if [[ "$COMMITTED" == 0 && -d "$STAGE/previous.app" ]]; then
    if [[ -e "$TARGET" ]]; then mv "$TARGET" "$STAGE/failed.app"; fi
    if mv "$STAGE/previous.app" "$TARGET"; then
      log "已回滚" "$TARGET"
      open "$TARGET" || true
    else
      log "回滚失败" "旧应用保留于 $STAGE/previous.app；请手动恢复"
      return "$status"
    fi
  elif [[ "$COMMITTED" == 0 && "$INSTALLED" == 1 ]]; then
    mv "$TARGET" "$STAGE/failed.app"
  fi
  rm -rf "$STAGE"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$SOURCE" "$STAGE/Perch.app"
codesign --verify --deep --strict "$STAGE/Perch.app"

PIDS="$(ps -axo pid=,comm= | awk '$2 == "/Applications/Perch.app/Contents/MacOS/Perch" { print $1 }')"
for pid in $PIDS; do
  log "退出中" "Perch ($pid)"
  kill -TERM "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    log "停止" "Perch 未在 5 秒内退出，旧应用未替换；请退出后重试"
    exit 1
  fi
done
if [[ -d "$TARGET" ]]; then mv "$TARGET" "$STAGE/previous.app"; fi
mv "$STAGE/Perch.app" "$TARGET"
INSTALLED=1
codesign --verify --deep --strict "$TARGET"
COMMITTED=1
open "$TARGET"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
log "已安装并启动" "$TARGET ($VERSION)"
