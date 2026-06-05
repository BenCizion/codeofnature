#!/usr/bin/env bash
# 선택 모듈: dev@cizion.com 의 CloudWatch ALARM 이메일을 독립적으로 수신 처리.
# EMAIL_APP_PASSWORD 미설정시 비활성. CloudWatch API 폴링(watch.sh)과 별개의 2차 경로.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"; source "$SCRIPT_DIR/lib.sh"
mkdir -p "$STATE_DIR"
[ -z "${EMAIL_APP_PASSWORD:-}" ] && exit 0

alarms="$(EMAIL_USER="$EMAIL_USER" EMAIL_APP_PASSWORD="$EMAIL_APP_PASSWORD" IMAP_HOST="${IMAP_HOST:-imap.gmail.com}" \
  python3 "$SCRIPT_DIR/email_fetch.py" 2>>"$STATE_DIR/watch.log")" || exit 0

for a in $alarms; do
  log "EMAIL ALARM $a"
  slack ":email: *[이메일 알람 수신]* \`$a\` — 진단 시작…"
  handle_alarm "$a"
done
