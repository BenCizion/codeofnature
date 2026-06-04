#!/usr/bin/env bash
# livere-watch 공통 함수 — watch.sh 에서 source

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$STATE_DIR/watch.log"; }

slack() {
  local text="$1"
  if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then echo "[slack-skip] $text"; return; fi
  curl -sf -X POST -H 'Content-type: application/json' \
    --data "{\"text\": $(json_str "$text")}" "$SLACK_WEBHOOK_URL" >/dev/null \
    || log "SLACK-FAIL: $text"
}

# 서킷브레이커: 같은 조치가 15분 내 2회 이상이면 차단
breaker_ok() {
  local f="$STATE_DIR/breaker_$1" now cutoff count
  now=$(date -u +%s); cutoff=$((now - 900))
  count=$(awk -v c="$cutoff" '$1>=c' "$f" 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -lt 2 ]
}
breaker_record() { echo "$(date -u +%s)" >> "$STATE_DIR/breaker_$1"; }

# 유일하게 프로덕션을 바꾸는 경로(결정적·고정 명령·감사로그). AUTONOMY=safe 일 때만 호출됨.
remediate_restart_api() {
  local out
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
    'sudo systemctl start livere-api-prod livere-scheduler-prod; sleep 3; systemctl is-active livere-api-prod livere-scheduler-prod' 2>&1)" || true
  log "REMEDIATE restart_api -> $out"
  slack ":arrows_counterclockwise: *재기동 결과* (\`$SSH_HOST\`)\n\`\`\`\n$out\n\`\`\`"
}

# 알람 1건 처리: 결정적 수집 → 도구없는 Claude 해석 → 가드레일
handle_alarm() {
  local alarm="$1" diag report decision

  # 1) 결정적 읽기전용 수집 (Claude가 아니라 셸이 함)
  diag="$(bash "$SCRIPT_DIR/collect.sh" 2>&1)"
  printf '%s\n' "$diag" > "$STATE_DIR/last_diag.txt"   # 감사용 원본 보관

  # 2) Claude = 도구 없는 해석기 (prod 실행 불가). 수집 텍스트만 근거.
  report="$("$CLAUDE_BIN" -p "$(cat "$SCRIPT_DIR/diagnose.prompt.md")

# 트리거된 알람
$alarm

# 수집된 읽기전용 진단 (이것만 근거로 판단. 너는 도구가 없다)
$diag" --allowedTools "" 2>>"$STATE_DIR/watch.log")" \
    || report="(Claude 해석 실패 — 로그 확인. 원본 진단: $STATE_DIR/last_diag.txt)"

  slack ":mag: *진단 리포트* (\`$alarm\`)\n$report"
  decision="$(grep -oE 'DECISION:[A-Za-z_:0-9 -]+' <<<"$report" | tail -1 | sed 's/^DECISION://')"
  log "DECISION($alarm)=${decision:-none}"

  # 3) 가드레일. 기본 observe = 자동 prod-write 안 함(승인 요청만).
  if [ "${AUTONOMY:-observe}" != "safe" ] && [ "${AUTONOMY:-observe}" != "aggressive" ]; then
    case "$decision" in
      SAFE_RESTART_API*) slack ":raising_hand: *권고: api 재기동 필요* (observe 모드 — 자동 실행 안 함)\n승인 시: \`ssh $SSH_HOST 'sudo systemctl start livere-api-prod livere-scheduler-prod'\`" ;;
      NEEDS_APPROVAL*)   slack ":raising_hand: *승인 필요* — ${decision#NEEDS_APPROVAL:} (런북 §2/§3)" ;;
    esac
    return
  fi

  # safe/aggressive: 단 하나의 화이트리스트 자동조치만
  case "$decision" in
    SAFE_RESTART_API*)
      if breaker_ok restart_api; then
        slack ":wrench: *[자동 안전조치]* api 비활성 → systemctl start"
        remediate_restart_api; breaker_record restart_api
      else
        slack ":no_entry: *[서킷브레이커]* 15분 내 재시작 반복 → 자동 중단. *사람 개입 필요.*"
      fi ;;
    NEEDS_APPROVAL*) slack ":raising_hand: *승인 필요* — ${decision#NEEDS_APPROVAL:} (위험조치는 항상 수동)" ;;
    *) slack ":information_source: 자동 조치 없음 (DECISION=${decision:-NONE})" ;;
  esac
}
