# livere-status-internal — 내부 전용 상태 대시보드

Cizion 내부에서 보는 **상세** 운영 상태 대시보드. 공개 `www.livere.com/status`(고객용, 서비스 레벨)와 별개로, **매체별 상태·인증경로·body 에러 상세**를 노출한다. 사내 IP에서만 접근 가능.

## 배경
2026-07-03 매일신문·뉴데일리 count 장애에서, 서비스-레벨 공개 프로버는 정상인데 **특정 매체만 깨지는** 사고를 못 잡았다. 내부 대시보드는 주요 언론사 19개를 개별 프로브해 매체별 다운을 즉시 노출한다.

## 구성
```
프로버(livere-status Lambda)
  ├─ 공개 status.json          → livere-com-web (누구나, 서비스 8개)
  └─ status-internal.json      → livere-status-internal 버킷 (사내 IP만, 서비스 + 매체 19개)
                                   ↑ INTERNAL_BUCKET env 있을 때만 발행 (없으면 dormant)
index.html (이 폴더)           → 같은 내부 버킷, status-internal.json 소비, 30초 자동갱신
```

## 데이터 (status-internal.json)
공개 status.json 스키마 + 추가 필드:
- `services[]` — 공개와 동일 (+ body_check 쓰는 서비스는 `bodyError` 상세)
- `press[]` — 주요 언론사 19개 개별 프로브: `{key, name, group(connect|major), clientId, status, httpCode, bodyError}`. widget-hash body_check(`data.client.id`)로 죽은 client 감지.
- `pressSummary` — `{total, operational, down}`

## 대시보드 (index.html)
- 단일 HTML, 외부 의존 없음(Pretendard CDN만). `status-internal.json`을 same-origin fetch.
- overall 배너 + 서비스 카드 그리드 + 매체 그리드(down 우선 정렬).
- 30초 자동 갱신. LiveRe 디자인(dash_mockup 색상/레이아웃 재활용).

## 셋업 (사내 IP 제한 S3)
```bash
export AWS_PROFILE=cizion-new
./setup.sh                    # dry-run — 버킷 정책 계획만 출력
./setup.sh --apply            # 실제: 버킷 생성 + IP제한 정책 + index.html 업로드
ALLOW_IPS="110.10.166.173/32,<추가IP>/32" ./setup.sh --apply   # 허용 IP 지정(기본=현재 공인IP)
```
접근: `http://livere-status-internal.s3-website.ap-northeast-2.amazonaws.com/` (사내 IP에서만)

### 프로버가 내부판 발행하도록 (셋업 후)
```bash
aws lambda update-function-configuration --function-name livere-status-prober \
  --environment 'Variables={INTERNAL_BUCKET=livere-status-internal}'
# + Lambda IAM role에 s3:PutObject on arn:aws:s3:::livere-status-internal/status-internal.json 추가
```
※ media-api count 프로브까지 켜려면 같은 env에 `MEDIAAPI_CANARY_KEY/SECRET/REFERER` 추가(카나리 키는 media-api 신계정 마이그레이션 때 발급).

## 매체 목록 갱신
`../livere-status/lambda_function.py`의 `PRESS` 리스트 + `../livere-deploy-check/press-list.json`을 함께 갱신(동기 유지).

## 관련
- 공개 프로버: `../livere-status/`
- 배포 회귀 체크: `../livere-deploy-check/`
- 내부 알림(Slack): `../livere-watch/`
