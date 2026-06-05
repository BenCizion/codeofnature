#!/usr/bin/env bash
# 결정적 읽기전용 진단 수집기. 프로덕션 변경 안 함. 마지막에 SIGNALS 라인 출력.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"
AWS=("$AWS_BIN" --profile "$AWS_PROFILE" --region "$AWS_REGION")
START=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "===== BACKEND (read-only) ====="
BK="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
  'echo APISTATE:$(systemctl is-active livere-api-prod); echo SCHEDSTATE:$(systemctl is-active livere-scheduler-prod); echo ---TOP---; top -bn1 | head -15; echo ---UP---; uptime; echo ---LOG---; sudo journalctl -u livere-api-prod -n 30 --no-pager' 2>&1)" || BK="(ssh 진단 실패)"
echo "$BK"
api_state="$(grep -m1 '^APISTATE:' <<<"$BK" | cut -d: -f2)"; api_state="${api_state:-unknown}"

echo
echo "===== ALB TARGET HEALTH (filter: ${TG_FILTER:-livere}) ====="
states=""
while read -r name arn; do
  [ -z "${arn:-}" ] && continue
  echo "-- $name"
  th="$("${AWS[@]}" elbv2 describe-target-health --target-group-arn "$arn" \
     --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text 2>&1)"
  echo "$th"
  states="$states $(awk '{print $2}' <<<"$th")"
done < <("${AWS[@]}" elbv2 describe-target-groups --query 'TargetGroups[].[TargetGroupName,TargetGroupArn]' --output text 2>/dev/null | grep -i -- "${TG_FILTER:-livere}")
healthy=$(printf '%s' "$states" | tr ' ' '\n' | grep -cx 'healthy' || true)

echo
echo "===== RDS CPU (15m) ====="
"${AWS[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=livere-production-db \
  --start-time "$START" --end-time "$END" --period 300 --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].{t:Timestamp,avg:Average,max:Maximum}' --output text 2>&1

echo
echo "===== EC2 CPU (15m, 10.0.147.210) ====="
cpu_max=0
EC2_ID=$("${AWS[@]}" ec2 describe-instances \
  --filters "Name=private-ip-address,Values=10.0.147.210" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
if [ -n "$EC2_ID" ] && [ "$EC2_ID" != "None" ]; then
  echo "instance: $EC2_ID"
  CM="$("${AWS[@]}" cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value="$EC2_ID" --start-time "$START" --end-time "$END" \
     --period 300 --statistics Maximum --query 'Datapoints[].Maximum' --output text 2>&1)"
  echo "max datapoints: $CM"
  cpu_max=$(printf '%s' "$CM" | tr '\t' '\n' | sort -nr | head -1)
  cpu_max=${cpu_max%.*}; cpu_max=${cpu_max:-0}
else
  echo "(EC2 인스턴스 조회 실패)"
fi

echo
echo "SIGNALS api=${api_state:-unknown} healthy=${healthy:-0} cpu=${cpu_max:-0}"
