#!/usr/bin/env bash
# E2E 매트릭스 실행 + Slack 매트릭스 보고. (livere-watch 의 Slack 웹훅 재사용)
set -uo pipefail
cd "$(dirname "$0")"

# Slack 웹훅: livere-watch config.env 에서 끌어옴(있으면)
if [ -z "${SLACK_WEBHOOK_URL:-}" ] && [ -f ../livere-watch/config.env ]; then
  # shellcheck disable=SC1091
  source ../livere-watch/config.env
fi
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

npx playwright test "$@" || true     # 실패해도 보고는 진행
node report.mjs
