#!/usr/bin/env bash
# livere-watch 설치: 의존성 확인 → 절대경로 주입 → launchd 등록 → Slack 테스트
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA="$HOME/Library/LaunchAgents"

[ -f "$SCRIPT_DIR/config.env" ] || { echo "✗ config.env 없음. 'cp config.env.example config.env' 후 값 채우기."; exit 1; }
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"

echo "▶ 의존성 확인"
for b in aws ssh python3 curl; do command -v "$b" >/dev/null || { echo "✗ $b 없음"; exit 1; }; done
CLAUDE_PATH="$(command -v claude || true)"; [ -n "$CLAUDE_PATH" ] || { echo "✗ claude CLI 없음 — Claude Code 설치/로그인 필요"; exit 1; }
AWS_PATH="$(command -v aws)"
[ -n "${SLACK_WEBHOOK_URL:-}" ] || { echo "✗ config.env 의 SLACK_WEBHOOK_URL 비어있음"; exit 1; }
[ -f "$REPO_DIR/docs/livere-incident-runbook.md" ] || echo "⚠ 런북 경로 확인: $REPO_DIR/docs/livere-incident-runbook.md (REPO_DIR 점검)"

echo "▶ 절대경로 주입 (config.env)"
/usr/bin/sed -i '' "s|^export CLAUDE_BIN=.*|export CLAUDE_BIN=\"$CLAUDE_PATH\"|" "$SCRIPT_DIR/config.env"
/usr/bin/sed -i '' "s|^export AWS_BIN=.*|export AWS_BIN=\"$AWS_PATH\"|" "$SCRIPT_DIR/config.env"

mkdir -p "$STATE_DIR" "$LA"
chmod +x "$SCRIPT_DIR/watch.sh"

echo "▶ launchd plist 설치"
/usr/bin/sed -e "s|__INSTALL_DIR__|$SCRIPT_DIR|g" -e "s|__STATE_DIR__|$STATE_DIR|g" \
  "$SCRIPT_DIR/com.cizion.livere-watch.plist" > "$LA/com.cizion.livere-watch.plist"
cp "$SCRIPT_DIR/com.cizion.livere-caffeinate.plist" "$LA/com.cizion.livere-caffeinate.plist"

echo "▶ launchd 로드"
for p in com.cizion.livere-watch com.cizion.livere-caffeinate; do
  launchctl unload "$LA/$p.plist" 2>/dev/null || true
  launchctl load "$LA/$p.plist"
done

echo "▶ Slack 테스트 전송 + 1회 실행"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"; source "$SCRIPT_DIR/config.env"
slack ":satellite: livere-watch 설치 완료 — 감시 시작 (자율도: $AUTONOMY)"
bash "$SCRIPT_DIR/watch.sh" || true

echo "✓ 완료. 로그: $STATE_DIR/watch.log / $STATE_DIR/launchd.err.log"
echo "  상태확인: launchctl list | grep livere"
