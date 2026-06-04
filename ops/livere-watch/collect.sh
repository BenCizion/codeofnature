#!/usr/bin/env bash
# 결정적 읽기전용 진단 수집기. 프로덕션을 절대 변경하지 않음(조회/로그만). 출력=텍스트.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/config.env"
AWS=("$AWS_BIN" --profile "$AWS_PROFILE" --region "$AWS_REGION")

START=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '15 min ago' +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "===== BACKEND (read-only) ====="
ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" \
  'systemctl is-active livere-api-prod livere-scheduler-prod; echo ---TOP---; top -bn1 | head -15; echo ---UP---; uptime; echo ---LOG---; sudo journalctl -u livere-api-prod -n 30 --no-pager' 2>&1 \
  || echo "(ssh 진단 실패)"

echo
echo "===== ALB TARGET HEALTH (filter: ${TG_FILTER:-livere}) ====="
"${AWS[@]}" elbv2 describe-target-groups \
  --query 'TargetGroups[].[TargetGroupName,TargetGroupArn]' --output text 2>&1 \
| grep -i -- "${TG_FILTER:-livere}" \
| while read -r name arn; do
    echo "-- $name"
    "${AWS[@]}" elbv2 describe-target-health --target-group-arn "$arn" \
      --query 'TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
      --output text 2>&1
  done

echo
echo "===== RDS CPU (15m) ====="
"${AWS[@]}" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=livere-production-db \
  --start-time "$START" --end-time "$END" --period 300 --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].{t:Timestamp,avg:Average,max:Maximum}' --output text 2>&1

echo
echo "===== EC2 CPU (15m, 10.0.147.210) ====="
EC2_ID=$("${AWS[@]}" ec2 describe-instances \
  --filters "Name=private-ip-address,Values=10.0.147.210" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)
if [ -n "$EC2_ID" ] && [ "$EC2_ID" != "None" ]; then
  echo "instance: $EC2_ID"
  "${AWS[@]}" cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="$EC2_ID" \
    --start-time "$START" --end-time "$END" --period 300 --statistics Average Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[].{t:Timestamp,avg:Average,max:Maximum}' --output text 2>&1
else
  echo "(EC2 인스턴스 조회 실패)"
fi
