#!/usr/bin/env bash
# livere-watch 공통 함수 — watch.sh / canary.sh / email_poll.sh 에서 source
NL=$'\n'

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$STATE_DIR/watch.log"; }

slack() {
  local text="$1"
  if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then echo "[slack-skip] $text"; return; fi
  curl -sf -X POST -H 'Content-type: application/json' \
    --data "{\"text\": $(json_str "$text")}" "$SLACK_WEBHOOK_URL" >/dev/null \
    || log "SLACK-FAIL: $text"
}

# ── 심각도 1~10 (결정적·잠정 기준, 추후 검토) ──────────────────────────────
awk_ge() { awk -v a="${1:-0}" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }
compute_severity() {  # api healthy cpu x5 lat canary
  local api="$1" healthy="${2:-1}" cpu="${3:-0}" x5="${4:-0}" lat="${5:-0}" canary="${6:-ok}" s=1
  if   awk_ge "$cpu" 95; then s=7
  elif awk_ge "$cpu" 85; then s=5
  elif awk_ge "$cpu" 70; then s=3; fi
  if   awk_ge "$x5" 1000; then [ "$s" -lt 8 ] && s=8
  elif awk_ge "$x5" 100;  then [ "$s" -lt 6 ] && s=6; fi
  if   awk_ge "$lat" 3000; then [ "$s" -lt 7 ] && s=7
  elif awk_ge "$lat" 1000; then [ "$s" -lt 4 ] && s=4; fi
  [ "$api" = inactive ] && [ "$s" -lt 9 ] && s=9
  [ "$canary" = fail ]  && [ "$s" -lt 9 ] && s=9
  [ "$healthy" = 0 ] && s=10
  [ "$s" -gt 10 ] && s=10
  echo "$s"
}
sev_bar() {  # 1~10 → 직관적 막대 + 라벨
  local s="$1" i bar="" label
  for i in $(seq 1 10); do [ "$i" -le "$s" ] && bar+="█" || bar+="░"; done
  if   [ "$s" -ge 9 ]; then label="🟥 치명 (서비스 다운/사용량 초과)"
  elif [ "$s" -ge 6 ]; then label="🟧 심각"
  elif [ "$s" -ge 3 ]; then label="🟨 주의"
  else                     label="🟩 정상"; fi
  echo "심각도 *$s/10* [$bar] $label"
}

# ── 서킷브레이커 ──────────────────────────────────────────────────────────
breaker_ok() {
  local f="$STATE_DIR/breaker_$1" now cutoff count
  now=$(date -u +%s); cutoff=$((now - 900))
  count=$(awk -v c="$cutoff" '$1>=c' "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -lt 2 ]
}
breaker_record() { echo "$(date -u +%s)" >> "$STATE_DIR/breaker_$1"; }

# ── 유일하게 프로덕션을 바꾸는 경로 (AUTONOMY=safe 일 때만 호출) ───────────
remediate_restart_api() {
  local out
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
    'sudo systemctl start livere-api-prod livere-scheduler-prod; sleep 3; systemctl is-active livere-api-prod livere-scheduler-prod' 2>&1)" || true
  log "REMEDIATE restart_api -> $out"
  slack ":arrows_counterclockwise: *재기동 결과* (\`$SSH_HOST\`)${NL}\`\`\`${NL}${out}${NL}\`\`\`"
}

# ── 알람 1건 처리: 결정적 수집 → 심각도 → 도구없는 Claude 해석 → 가드레일 ──
handle_alarm() {
  local alarm="$1" diag report decision sig api healthy cpu sev

  diag="$(bash "$SCRIPT_DIR/collect.sh" 2>&1)"
  printf '%s\n' "$diag" > "$STATE_DIR/last_diag.txt"

  sig="$(grep -m1 '^SIGNALS ' <<<"$diag" || true)"
  api="$(sed -n 's/.*api=\([^ ]*\).*/\1/p' <<<"$sig")"
  healthy="$(sed -n 's/.*healthy=\([^ ]*\).*/\1/p' <<<"$sig")"
  cpu="$(sed -n 's/.*cpu=\([^ ]*\).*/\1/p' <<<"$sig")"
  sev="$(compute_severity "${api:-unknown}" "${healthy:-1}" "${cpu:-0}" "" "" ok)"

  # Claude = 도구 없는 해석기(prod 실행 불가). 수집 텍스트만 근거.
  report="$("$CLAUDE_BIN" -p "$(cat "$SCRIPT_DIR/diagnose.prompt.md")

# 트리거된 알람
$alarm

# 수집된 읽기전용 진단 (이것만 근거로 판단. 너는 도구가 없다)
$diag" --allowedTools "" 2>>"$STATE_DIR/watch.log")" \
    || report="(Claude 해석 실패 — 로그 확인. 원본: $STATE_DIR/last_diag.txt)"

  slack ":mag: *진단* (\`$alarm\`) — $(sev_bar "$sev")${NL}${report}"
  decision="$(grep -oE 'DECISION:.+' <<<"$report" | tail -1 | sed 's/^DECISION://')"
  log "DECISION($alarm)=${decision:-none} sev=$sev"

  if [ "${AUTONOMY:-observe}" != "safe" ] && [ "${AUTONOMY:-observe}" != "aggressive" ]; then
    case "$decision" in
      SAFE_RESTART_API*) slack ":raising_hand: *권고: api 재기동 필요* (observe — 자동 실행 안 함)${NL}승인 시: \`ssh $SSH_HOST 'sudo systemctl start livere-api-prod livere-scheduler-prod'\`" ;;
      NEEDS_APPROVAL*)   slack ":raising_hand: *승인 필요* — ${decision#NEEDS_APPROVAL:}" ;;
    esac
    return
  fi
  case "$decision" in
    SAFE_RESTART_API*)
      if breaker_ok restart_api; then
        slack ":wrench: *[자동 안전조치]* api 비활성 → systemctl start"
        remediate_restart_api; breaker_record restart_api
      else
        slack ":no_entry: *[서킷브레이커]* 재시작 반복 → 자동 중단. *사람 개입 필요.*"
      fi ;;
    NEEDS_APPROVAL*) slack ":raising_hand: *승인 필요* — ${decision#NEEDS_APPROVAL:} (위험조치는 항상 수동)" ;;
    *) slack ":information_source: 자동 조치 없음 (DECISION=${decision:-NONE})" ;;
  esac
}
