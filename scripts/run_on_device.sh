#!/usr/bin/env bash
# 実機へ「ビルド → インストール → 起動 → ログ回収」を1コマンドで行う（Mac専用）。
#
# 使い方:
#   scripts/run_on_device.sh              # ビルドして入れて起動し、ログを表示
#   scripts/run_on_device.sh --wait 20    # 起動後 20 秒待ってからログを回収（操作の余裕）
#   scripts/run_on_device.sh --no-build   # ビルドせず、前回のビルドを入れ直す
#   scripts/run_on_device.sh --log-only   # ビルド/インストール/起動なし。いまのログだけ回収
#   scripts/run_on_device.sh --args "--selftest"   # 起動引数を渡す（自動テストモード用）
#
# 設定は scripts/device.env（scripts/device.env.example を参照）。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

ENV_FILE="scripts/device.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "scripts/device.env がありません。scripts/device.env.example を参考に作ってください。" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${TEAM_ID:?device.env に TEAM_ID がありません}"
: "${DEVICE:?device.env に DEVICE（UDID）がありません}"
: "${BUNDLE_ID:?device.env に BUNDLE_ID がありません}"

WAIT=0
DO_BUILD=1
DO_INSTALL=1
LAUNCH_ARGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT="${2:?--wait には秒数を渡してください}"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --log-only) DO_BUILD=0; DO_INSTALL=0; shift ;;
    --args) LAUNCH_ARGS="${2:?--args には引数文字列を渡してください}"; shift 2 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

APP_PATH="build/Build/Products/Debug-iphoneos/LogPhoto.app"
mkdir -p logs build
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="logs/device-$STAMP.log"

# --- 1. ビルド ---
if [[ $DO_BUILD -eq 1 ]]; then
  echo "==> xcodegen generate"
  xcodegen generate >/dev/null
  echo "==> ビルド中（数分かかることがあります）"
  if ! xcodebuild build -project LogPhoto.xcodeproj -scheme LogPhoto \
        -configuration Debug -destination 'generic/platform=iOS' \
        -derivedDataPath build -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        > "build/xcodebuild-$STAMP.log" 2>&1; then
    echo "!! ビルド失敗。エラー:" >&2
    grep -E "error:" "build/xcodebuild-$STAMP.log" | sed "s#$ROOT/##" | sort -u | head -30 >&2 || true
    echo "（全ログ: build/xcodebuild-$STAMP.log）" >&2
    exit 2
  fi
  echo "    ビルド成功"
fi

# --- 2. インストール ---
if [[ $DO_INSTALL -eq 1 ]]; then
  [[ -d "$APP_PATH" ]] || { echo "!! $APP_PATH がありません。--no-build を外してください" >&2; exit 1; }
  echo "==> インストール"
  if ! xcrun devicectl device install app --device "$DEVICE" "$APP_PATH" >/dev/null 2>"build/install-$STAMP.err"; then
    echo "!! インストール失敗（iPhone が接続・ロック解除されているか確認）:" >&2
    cat "build/install-$STAMP.err" >&2
    exit 3
  fi

  # --- 3. 起動（コンソールには張り付かず、すぐ戻る） ---
  echo "==> 起動"
  LAUNCH=(xcrun devicectl device process launch --device "$DEVICE")
  # shellcheck disable=SC2206
  ARGS=($LAUNCH_ARGS)
  if ! "${LAUNCH[@]}" --terminate-existing "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>"build/launch-$STAMP.err"; then
    # 古い devicectl では --terminate-existing が無いことがあるので、無しで再試行する
    if ! "${LAUNCH[@]}" "$BUNDLE_ID" ${ARGS[@]+"${ARGS[@]}"} >/dev/null 2>>"build/launch-$STAMP.err"; then
      echo "!! 起動失敗（iPhone のロックを解除してください）:" >&2
      cat "build/launch-$STAMP.err" >&2
      exit 4
    fi
  fi
fi

# --- 4. 待機してログ回収 ---
if [[ "$WAIT" -gt 0 ]]; then
  echo "==> ${WAIT}秒待機（この間に iPhone を操作できます）"
  sleep "$WAIT"
fi

echo "==> ログ回収"
if ! xcrun devicectl device copy from --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source Documents/logphoto-debug.log --destination "$LOG_FILE" >/dev/null 2>"build/copy-$STAMP.err"; then
  echo "!! ログの回収に失敗:" >&2
  cat "build/copy-$STAMP.err" >&2
  exit 5
fi
echo "    保存先: $LOG_FILE"

# 直近の起動以降だけを表示する（過去の起動分は省く）
echo "----- 直近の起動からのログ -----"
LAST_LAUNCH_LINE=$(grep -n "===== launch" "$LOG_FILE" | tail -1 | cut -d: -f1 || true)
if [[ -n "${LAST_LAUNCH_LINE:-}" ]]; then
  tail -n +"$LAST_LAUNCH_LINE" "$LOG_FILE"
else
  cat "$LOG_FILE"
fi
