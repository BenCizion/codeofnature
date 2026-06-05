#!/usr/bin/env bash
# livere-watch 메인 — launchd 가 60초마다 실행
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
mkdir -p "$STATE_DIR"

# 동시 실행 방지(중복 알림·진단 겹침 방지). Claude 진단이 60초 넘으면 다음 틱은 skip.
LOCK="$STATE_DIR/watch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # 10분 넘은 스테일 락은 회수
  if find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null | grep -q .; then
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

AWS=("$AWS_BIN" --profile "$AWS_PROFILE" --region "$AWS_REGION")

# 0) 하트비트(워처 생존) → CloudWatch 커스텀 지표 + 로컬 타임스탬프
"${AWS[@]}" cloudwatch put-metric-data --namespace LivereWatch \
  --metric-name WatcherHeartbeat --value 1 >/dev/null 2>&1 || true
date -u +%s > "$STATE_DIR/heartbeat"

# 1) 현재 ALARM 상태인 알람 목록
current="$("${AWS[@]}" cloudwatch describe-alarms \
  --state-value ALARM --alarm-name-prefix "$ALARM_PREFIX" \
  --query 'MetricAlarms[].AlarmName' --output text 2>>"$STATE_DIR/watch.log")"
[ "$current" = "None" ] && current=""

prev_file="$STATE_DIR/active_alarms"
prev="$(cat "$prev_file" 2>/dev/null || true)"

# 2) 복구 감지 (이전 ALARM → 현재 해제)
for a in $prev; do
  if ! grep -qw -- "$a" <<<"$current"; then
    slack ":white_check_mark: *[복구]* 알람 \`$a\` 정상(OK) 회복."
    log "RECOVERED $a"
  fi
done

# 3) 신규 ALARM 처리 (먼저 상태 저장 → 진단 중 다음 틱이 중복 발사하지 않게)
printf '%s\n' $current > "$prev_file"
for a in $current; do
  if ! grep -qw -- "$a" <<<"$prev"; then
    log "NEW ALARM $a"
    slack ":rotating_light: *[장애 감지]* \`$a\` ALARM. Claude 자동 진단 시작…"
    handle_alarm "$a"
  fi
done
