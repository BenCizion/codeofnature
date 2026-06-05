#!/usr/bin/env bash
# 독립 캐너리: 주기(기본 1h)마다 댓글 위젯/ API 정상출력·응답시간 점검 → 심각도 Slack.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"; source "$SCRIPT_DIR/lib.sh"
mkdir -p "$STATE_DIR"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

fails=0; worst=0; lines=""
ms_of() { awk -v t="$1" 'BEGIN{printf "%d", t*1000}'; }
checkurl() {  # name url [min_bytes]
  local name="$1" url="$2" minb="${3:-0}" r code t ms size
  if [ -z "$url" ]; then lines+="• $name: (URL 미설정)
"; return; fi
  r="$(curl -s -o "$tmp" -w '%{http_code} %{time_total}' --max-time 20 "$url" 2>/dev/null || echo '000 0')"
  code="${r% *}"; t="${r##* }"; ms="$(ms_of "$t")"; size="$(wc -c <"$tmp" 2>/dev/null || echo 0)"
  [ "$ms" -gt "$worst" ] && worst="$ms"
  if [ "$code" = 200 ] && [ "${size:-0}" -ge "$minb" ]; then
    lines+="• $name: ✅ 200 (${ms}ms, ${size}B)
"
  else
    fails=$((fails+1)); lines+="• $name: ❌ HTTP $code (${ms}ms, ${size}B)
"
  fi
}

checkurl "위젯 main.js"  "${CANARY_WIDGET_JS_URL:-}"
checkurl "API 헬스"      "${CANARY_API_HEALTH_URL:-}"
checkurl "댓글 API 출력" "${CANARY_COMMENTS_URL:-}" 3   # 200 + 본문(>2B) 이어야 정상

# 심각도(잠정 기준 — 추후 검토). 사용량/지연/실패 반영.
if   [ "$fails" -ge 2 ]; then sev=10
elif [ "$fails" -eq 1 ]; then sev=9
elif [ "$worst" -ge 3000 ]; then sev=7
elif [ "$worst" -ge "${CANARY_MAX_MS:-2000}" ]; then sev=5
elif [ "$worst" -ge 1000 ]; then sev=3
else sev=1; fi

"$AWS_BIN" --profile "$AWS_PROFILE" --region "$AWS_REGION" cloudwatch put-metric-data \
  --namespace LivereWatch --metric-name CanaryUp --value "$([ "$fails" -eq 0 ] && echo 1 || echo 0)" >/dev/null 2>&1 || true
log "CANARY fails=$fails worst=${worst}ms sev=$sev"

# 이상시에만 알림(정상은 조용히). 필요하면 일1회 요약은 추후.
if [ "$fails" -gt 0 ] || [ "$worst" -ge "${CANARY_MAX_MS:-2000}" ]; then
  slack ":satellite_antenna: *위젯 캐너리 점검* — $(sev_bar "$sev")
$lines"
fi
