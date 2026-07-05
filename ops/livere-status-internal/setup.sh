#!/usr/bin/env bash
# livere-status-internal — 내부 전용 상태 대시보드 인프라 셋업 (사내 IP 제한 S3)
#
# 무엇을 만드나:
#   1) S3 버킷 (기본 livere-status-internal) — 정적 웹 호스팅, 사내 IP만 허용
#   2) 버킷 정책 (IP whitelist) — index.html + status-internal.json 접근 제한
#   3) index.html 업로드
#   ※ 프로버 Lambda가 status-internal.json을 이 버킷에 발행하도록
#      env INTERNAL_BUCKET 설정은 별도 (아래 안내). 시크릿 아님.
#
# 사용:
#   AWS_PROFILE=cizion-new ./setup.sh              # dry-run (계획만 출력)
#   AWS_PROFILE=cizion-new ./setup.sh --apply      # 실제 생성
#   ALLOW_IPS="110.10.166.173/32,1.2.3.4/32" ...   # 허용 IP override (기본=현재 공인IP)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUCKET="${INTERNAL_BUCKET:-livere-status-internal}"
REGION="${AWS_REGION:-ap-northeast-2}"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

# 허용 IP: 기본은 현재 공인 IP/32. 여러 개면 ALLOW_IPS=csv 로.
if [ -z "${ALLOW_IPS:-}" ]; then
  MYIP="$(curl -s -m 10 https://api.ipify.org)"
  ALLOW_IPS="${MYIP}/32"
fi
# csv → JSON array
IPS_JSON="$(python3 -c "import sys,json; print(json.dumps([x.strip() for x in sys.argv[1].split(',') if x.strip()]))" "$ALLOW_IPS")"

echo "=== livere-status-internal 셋업 ==="
echo "  버킷:     $BUCKET ($REGION)"
echo "  허용 IP:  $ALLOW_IPS"
echo "  적용:     $([ $APPLY = 1 ] && echo '실제 생성(--apply)' || echo 'dry-run (계획만)')"
echo ""

POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowOfficeIPsOnly",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": { "IpAddress": { "aws:SourceIp": ${IPS_JSON} } }
  }]
}
JSON
)"

if [ $APPLY = 0 ]; then
  echo "[dry-run] 생성할 버킷 정책:"
  echo "$POLICY"
  echo ""
  echo "[dry-run] 실제 생성하려면: AWS_PROFILE=$AWS_PROFILE ./setup.sh --apply"
  exit 0
fi

# 1) 버킷 생성 (이미 있으면 무시)
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "버킷 이미 존재: $BUCKET"
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
  echo "버킷 생성: $BUCKET"
fi

# 2) 정적 웹 호스팅
aws s3 website "s3://$BUCKET" --index-document index.html

# 3) Public Access Block 완화 (버킷 정책 IP 제한을 쓰므로 정책 허용 필요)
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# 4) IP 제한 버킷 정책
echo "$POLICY" > /tmp/status-internal-policy.json
aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/status-internal-policy.json
rm -f /tmp/status-internal-policy.json
echo "IP 제한 정책 적용"

# 5) 대시보드 업로드
aws s3 cp "$DIR/index.html" "s3://$BUCKET/index.html" \
  --content-type "text/html; charset=utf-8" --cache-control "no-cache"
echo "index.html 업로드"

echo ""
echo "=== 완료 ==="
echo "접근 URL: http://$BUCKET.s3-website.$REGION.amazonaws.com/  (사내 IP에서만)"
echo ""
echo "★다음: 프로버 Lambda가 이 버킷에 발행하도록 env 설정:"
echo "  aws lambda update-function-configuration --function-name livere-status-prober \\"
echo "    --environment 'Variables={INTERNAL_BUCKET=$BUCKET}'"
echo "  + Lambda IAM role에 s3:PutObject on arn:aws:s3:::$BUCKET/status-internal.json 추가"
