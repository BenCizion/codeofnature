---
aliases:
  - 라이브리 장애
  - 라이브리 신버전 장애
  - LiveRe 장애
  - livere 장애 대응
  - livere outage
tags:
  - runbook
  - incident
  - livere
  - ops/oncall
created: 2026-06-04
updated: 2026-06-04
---

# 🚨 라이브리(LiveRe v.11) 장애 대응 Runbook

> [!tip] 트리거
> "**라이브리 장애**" / "**라이브리 신버전 장애**" 라고 하면 → **이 문서부터** 연다.

## 0. 30초 핵심 (먼저 읽기)
- 위젯 "느림 / 안 뜸" 장애의 **1순위 원인 = 백엔드 EC2 CPU 포화** (DB가 아닌 경우가 많다).
- ⚠️ 운영 매뉴얼의 원인 가정("트래픽발 DB 부하")을 **맹신 금지** — **측정부터** 한다.
- 🪤 알려진 함정 2가지:
  1. **배치 작업이 CPU 폭주**를 일으킨다 (2026-06-04 실제 원인).
  2. `livere-api-prod` / `livere-scheduler-prod` 가 systemd **`disabled`** 상태 → **EC2 인스턴스를 리부트하면 자동 기동이 안 됨 = 완전 다운.** 리부트했으면 **반드시 수동 start**.
- ❌ **RDS 재시작은 최후의 수단.** (전체 다운/페일오버 + 콜드캐시) 측정으로 DB 병목을 확인하기 전엔 건드리지 말 것.

## 1. 빠른 진단 (측정 먼저, ~5분)

### 1-1. AWS CLI 준비 (mac)
named-profile 라 `--profile` 또는 `AWS_PROFILE` 필수 (`default` 프로파일 없음).
```bash
export AWS_PROFILE=cizion-new      # prod 계정 360055708600
export AWS_REGION=ap-northeast-2
export AWS_DEFAULT_REGION=ap-northeast-2
aws sts get-caller-identity        # Account 360055708600 확인
```

### 1-2. RDS 상태·지표
```bash
export RDS_ID=livere-production-db
export START=$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)   # ← macOS date 문법
export END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,Class:DBInstanceClass}' --output table
for M in CPUUtilization DatabaseConnections FreeableMemory ReadIOPS WriteIOPS; do
  echo "== RDS $M =="
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name "$M" \
    --dimensions Name=DBInstanceIdentifier,Value="$RDS_ID" \
    --start-time "$START" --end-time "$END" --period 300 --statistics Average Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[].{t:Timestamp,avg:Average,max:Maximum}' --output table
done
```
**판독:** CPU < 10% & FreeableMemory 여유 & Connections 한참 아래 → **DB 정상, 병목 아님.**

### 1-3. 백엔드 EC2 지표
```bash
export EC2_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=10.0.147.210" \
  --query 'Reservations[].Instances[].InstanceId' --output text)   # 현재 i-0d311a516c68ea6a2
for M in CPUUtilization NetworkIn NetworkOut; do
  echo "== EC2 $M =="
  aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name "$M" \
    --dimensions Name=InstanceId,Value="$EC2_ID" \
    --start-time "$START" --end-time "$END" --period 300 --statistics Average Maximum \
    --query 'sort_by(Datapoints,&Timestamp)[].{t:Timestamp,avg:Average,max:Maximum}' --output table
done
```
**판독:** CPU **90%+ 지속 = 범인.**

### 1-4. SSH 백엔드 직접 확인
```bash
ssh livere-prod 'top -bn1 | head -20; echo ---; \
  systemctl is-active livere-api-prod livere-scheduler-prod; \
  uptime; free -h'
```
- `~/.ssh/config` 에 `livere-prod`(ProxyJump = bastion `3.39.48.112:234`, 키 `~/.ssh/livere.livere.pem`) 설정됨. **VPN 없이** 접속.
- 확인: 어떤 프로세스가 CPU를 먹는지(api? scheduler/배치?), `uptime`(리부트 직후면 `up N min`), 서비스 active 여부.

## 2. 의사결정 트리
- **EC2 CPU 포화 + 범인이 배치/scheduler** → 그 배치 중단 / 스케줄 조정. (재시작·리부트 불필요)
- **EC2 CPU 포화 + api 트래픽** → 스케일아웃 or 핫픽스.
- **EC2 리부트 했는데 위젯 죽음** → api `disabled` 라 안 올라온 것 → **수동 start (3-1)**.
- **DB 지표 포화(드묾)** → 스케일업 우선, RDS 재시작은 최후.

## 3. 복구 액션
### 3-1. 백엔드 기동 (리부트/다운 후 필수)
```bash
ssh livere-prod 'sudo systemctl start livere-api-prod livere-scheduler-prod; sleep 3; \
  systemctl is-active livere-api-prod livere-scheduler-prod'
```
### 3-2. 부팅 자동기동 켜기 (재발 방지)
```bash
ssh livere-prod 'sudo systemctl enable livere-api-prod livere-scheduler-prod'
```
### 3-3. 스케일 (매뉴얼 3단계) — 부하가 진짜일 때만
- 백엔드 스케일아웃/업, 또는 RDS 인스턴스 클래스 상향. **DB는 대부분 불필요.**

## 4. 재발 방지 / 개선 백로그
- [ ] `livere-api-prod`·`livere-scheduler-prod` **`enable`** (리부트 시 자동 복구) — 미적용 시 리부트 = 완전 다운.
- [ ] **배치 작업을 운영 백엔드와 분리** 또는 저트래픽 시간대 + CPU 제한(nice/cgroup). 배치 CPU 폭주가 2026-06-04 장애 원인.
- [ ] 운영 매뉴얼의 "원인 = DB 부하" 가정 수정 → "EC2 CPU 우선 확인".
- [ ] 백엔드 CPU/load 알람(CloudWatch) 임계치 설정.
- [ ] **마이그레이션/배치의 prod 공개 API 고속호출 금지** — 스로틀(워커 1~2/초당 수 건)+야간, 또는 DB직접/전용 경로. (2026-06-05 client 대량생성이 FD/CPU 고갈로 전면장애)
- [ ] **client 생성/체크 엔드포인트 rate-limit** (`CheckPropsAvailability`, `POST /api/v1/clients`).
- [ ] **`LimitNOFILE=1,000,000` 영구 유지** (drop-in 적용됨 — FD 고갈로 인한 사망/크래시루프 방지).
- [ ] **FD·CLOSE-WAIT 알람** 추가 (api 프로세스 FD 수 / :8000 CLOSE-WAIT 적체).

## 5. 인프라 레퍼런스
| 항목 | 값 |
|---|---|
| AWS 계정 | 360055708600 (`AWS_PROFILE=cizion-new`, ap-northeast-2) |
| Prod RDS | `livere-production-db` (db.m7g.2xlarge, PG15, Single-AZ) |
| Prod 백엔드 EC2 | `ssh livere-prod` 경유 — 2026-06-19 m7g.2xlarge right-size 완료(§7①). 구 8xlarge는 stop(`ssh livere-prod-blue-old`=롤백). instance-id/IP는 로컬 보관 |
| Bastion | `3.39.48.112:234` (`ssh livere-prod`, ProxyJump) |
| SSH 키 | `~/.ssh/livere.livere.pem` |
| 서비스 | `livere-api-prod`, `livere-scheduler-prod` (systemd) |
| Dev/Staging | `54.180.144.250` (`ssh livere-stage`, 키 `leclexcizion.pem`) |

> [!note] 출처
> 운영/배포 절차 원문 = Confluence "Jady - Draft"(이정대 CTO 인수인계 문서) 및 Drive `1.4. 운영 매뉴얼` / `장애처리가이드`.

## 6. 인시던트 로그
### 2026-06-04 — 운영 위젯 장애 (배치 CPU 폭주)
- **증상**: 라이브리 v.11 위젯 느림 / 안 뜸.
- **타임라인(KST)**: 09:23~09:48 백엔드 EC2 CPU 95~99% 지속 → 1차 대응으로 백엔드 재시작·RDS 재시작 → EC2 인스턴스 리부트(서버 시계 UTC) 후 api `disabled` 라 자동 기동 안 됨(완전 다운 위험) → 이정대(Jady, CTO) 수동 복구.
- **측정 결과**: RDS 정상(CPU ~3%, FreeableMemory ~22GB, 커넥션 미포화). **EC2 CPU 포화가 진짜 원인.** RDS 재시작은 불필요했음.
- **근본 원인(Jady)**: **이전 배치 작업의 CPU 폭주.** 해당 배치는 **오늘 저녁 이어서 진행 예정** → 재폭주 가능.
- **복구**: api/scheduler `active`, 위젯 정상 (up 5min, load 4.66 회복 중).
- **교훈**: ① DB부터 의심 금지, EC2 CPU 먼저. ② EC2 리부트 시 서비스 수동 start(또는 enable) 필수. ③ 배치를 운영 백엔드에서 분리.

> [!warning] 오늘 저녁 주의 (2026-06-04 저녁)
> 배치 작업 재개 예정 → **CPU 재폭주 가능.** 1-3 / 1-4 로 EC2 CPU 선제 모니터링.

### 2026-06-05 — 운영 전면 장애 (v9→v11 마이그레이션이 client 대량생성)
- **증상**: 위젯·로그인·`/clients/{id}/profile`·`/clients/articles/stats` 504/CORS. ~10:00~11:15(KST, UTC 01:00~02:13) 반복 다운·재시작.
- **근본 원인 (확정)**: **v9→v11 사이트 마이그레이션 배치가 prod client 생성 API(`POST /api/v1/clients`)를 고속·고동시성으로 호출**. = 2026-06-04 "배치 CPU 폭주"의 정체이자 연속.
  - 증거: `livere_prod_clients` 중 `email='dev@cizion.com'` 소유 client가 **4 → 5,914 (수 분)**, 전부 실제 v9 사이트(tistory/google sites 등), create_at이 장애시각과 일치.
  - **인과 확정**: 배치 **중지→prod 즉시 회복**(동시연결 32k→~300, FD 47k→194, 응답 0.05s), **재개→재다운**. RDS는 한가(CPU<6%, latency~0) → **DB 아님, api 측 동시성 병목.**
- **메커니즘 (FD 고갈)**: 생성 폭주로 DB 풀(100) 포화 → 후속 핸들러가 빈 커넥션 대기로 블록 → ALB가 끊은 연결이 **CLOSE-WAIT로 적체 → 프로세스 FD 폭증** → 원래 상한 49,152 도달 시 **RDS 소켓·DNS조차 못 열어** 전면 실패(`too many open files`) → `FATAL context deadline exceeded` → (이전엔)크래시루프/인스턴스 리부트. ※ FD = api가 붙들고 있는 연결/파일 수, 평시 ~70~300 / 폭주 시 47,000.
- **조치**:
  1. systemd drop-in **`LimitNOFILE` 49,152 → 1,000,000** (`/etc/systemd/system/livere-api-prod.service.d/override.conf`) → FD 천장 도달로 **죽는 크래시루프 차단**(degraded는 되나 사망·리부트 방지). **유지할 것.**
  2. api `models/base.go` **`findPage()` 고루틴 누수 패치**(병렬 Find/Count → 순차) staging→prod 배포(빌드ID `b3dea9d`). 부수 개선(이 건의 주원인은 아님). prod 바이너리 백업 `api.bak.findpage.*`.
  3. **배치 중지**(이정대 CTO) → prod 회복. = 유일한 실질 해결.
- **교훈 / 재발방지**:
  - 마이그레이션은 **스로틀**(워커 1~2개, 초당 수 건) + **야간**에만. prod 공개 API 고속호출 대신 DB 직접/전용 배치 경로 검토.
  - api 내성: **client 생성/체크 엔드포인트 rate-limit**(생성 버스트에 운영이 무너지면 안 됨).
  - 진단 시 **FD·CLOSE-WAIT 수**를 1차 지표로(아래 1-4에 추가): `sudo ls /proc/$(pgrep -f /home/ubuntu/livere/api/api|head -1)/fd | wc -l`, `ss -tan | awk '$4~/:8000$/{print $1}' | sort | uniq -c`.
  - "already registered" 로그 0이라도 **신규 생성은 성공(무에러)** 이라 폭주가 숨음 → `SELECT count(*) ... WHERE create_at > now-60s` 로 생성률 확인.

### 2026-06-06 — iOS 모바일 로그인 실패 (서버 아님, 추후 점검 TODO)
- **증상**: 아이폰 크롬/서울신문 = 로그인 버튼 무반응, 아이폰 사파리/국민일보 = 로그인 클릭 시 무한 리프레시. 댓글(오마이뉴스)은 모바일에서도 정상.
- **결정적 크로스체크**: **같은 사이트가 데스크톱에선 정상**(맥 크롬/서울신문 ✓, 맥 사파리/국민일보 ✓). → 서버·Keycloak(vault)·realm·client 설정 문제 아님(그랬다면 데스크톱도 실패). **vault 교체 회귀 가설은 이 매트릭스로 반증됨.**
- **유력 원인(미확정)**: iOS 한정 — **ITP/서드파티 쿠키 차단**으로 cross-site 인증 세션 쿠키가 막혀 redirect 루프(사파리 무한 리프레시), 또는 모바일 로그인 분기(popup→redirect) 차이. 댓글은 cross-site 인증 쿠키 불필요 → 모바일 정상과 일관.
- **상태**: 라이브리 서비스 장애 아님 → 비상대응 불필요. **추후 점검**. 점검 시작점: ① 데스크톱↔모바일 환경 매트릭스부터(서버 파기 전), ② iOS Safari 개발자도구로 redirect 체인·차단된 Set-Cookie(SameSite/서드파티) 확인, ③ 모바일 signinRedirect 분기 `redirect_uri` query 보존(앞선 OIDC query string 충돌 이력과 연계).
- **방법론 교훈**: 로그인 장애는 **환경 매트릭스(데스크톱/모바일 × 브라우저)부터** 잡을 것. iOS만 실패면 ITP/쿠키지 서버 아님 — 서버 깊이 파기 전에 이 한 줄로 분기.

### 2026-06-09 — 서울신문·매일신문 간헐적 위젯 미노출 (CDN CORS 캐시 버그)
- **증상**: PC(`www.seoul.co.kr`)에서 라이브리 위젯이 **간헐적** 미표시. 콘솔: `Access to fetch at '.../api/v2/widget-hash?client_id=...' from origin 'https://www.seoul.co.kr' blocked by CORS: 'Access-Control-Allow-Origin' has a value 'https://m.seoul.co.kr'` → `Could not load the script! (livere-widget.js:88)`.
- **근본 원인 (확정)**: `/api/v2/widget-hash`는 요청 Origin을 ACAO로 **반영(reflect)** 하는데, 응답이 `cache-control: public, max-age=60`으로 **CloudFront에 캐시**되고 **그 캐시 정책(`GetWidgetHashCachePolicy`)의 캐시키에 `Origin`이 없었음(`HeaderBehavior: none`)**. → 엣지 캐시를 먼저 채운 origin(www냐 m이냐)이 TTL 동안 승자가 되어, 반대편 사용자는 ACAO 불일치로 CORS 차단. `www`+`m`(또는 amp) 서브도메인을 쓰는 **전 고객사 시스템적 영향**. (정책이 06-07 23:50 추가되며 캐싱이 켜진 게 발단.)
- **조치 (코드 배포 불필요)**: CloudFront 캐시 정책 `GetWidgetHashCachePolicy`(id `33c25813-...`, 배포 `E7Y6B8K98DHGR`/api.livere.org, profile `cizion-new`)의 **캐시키 헤더에 `Origin` 추가**(`none`→`whitelist:[Origin]`). → origin별 분리 캐시 → 각자 자기 ACAO 수신. 무효화로는 60초 후 재발이라 **안 됨**.
- **후속**: 앱 응답에 `Vary: Origin` 추가(타 CDN/브라우저 캐시 정석 — Jady).

### 🔁 CORS 미노출 진단 퀵체크 (재발 잦음 — 이 패턴부터 의심)
1. 콘솔에서 `widget-hash` fetch가 CORS 차단인지 확인. ACAO 값이 **요청 origin과 다른 서브도메인**이면 = CDN 캐시키에 Origin 누락.
2. 재현(read-only): 한 origin으로 캐시 채운 뒤 다른 origin 요청 → ACAO가 안 바뀌고 `x-cache: Hit`면 확정.
   ```bash
   U="https://api.livere.org/api/v2/widget-hash?client_id=<CID>"
   curl -s -D- -o/dev/null -H "Origin: https://m.<site>"   "$U" | grep -i 'allow-origin\|x-cache'
   curl -s -D- -o/dev/null -H "Origin: https://www.<site>" "$U" | grep -i 'allow-origin\|x-cache'
   ```
3. 점검: 해당 경로 CloudFront **캐시 정책의 캐시키에 `Origin` 포함** 여부 + 응답 `Vary: Origin` 유무.
4. 해결: 캐시키에 `Origin` 추가(앱 미수정으로 즉효) + 앱 `Vary: Origin`. ⚠️ 캐시 무효화는 TTL 후 재발이라 근본해결 아님.

## 7. Follow-up 전략 (2026-06-06 마이그레이션 폭주 사후, CTO 1차 패치 후)

CTO(Jady) 1차 패치 완료 — API 스팸패턴 차단 / OIDC retry 제어 / backend 안전망 / scheduler cronjob 관측성·프로세스 정리 / V2 JWKS 캐시 강화 / 로깅 개선·pprof 도입. **→ CPU ~4% 안정.** 이후 후속 과제 3종.
※ 구체 인프라 식별자(instance-id, ALB ARN 등)는 본 GitHub 문서에 두지 않음 — 예약작업(로컬 `~/.claude/scheduled-tasks/`) 및 HR 로컬에 보관.

### ① 인스턴스 right-size (단기·비용) — ✅ **완료 2026-06-19 (블루/그린 무중단)**
- 06-08~14 7일 관측: 업무시간 정상 피크 **~9%**(실수요 ~2.9 vCPU). 06-11 86% 급등은 배포 사고(롤백 완료)지 상시 회귀 아님.
- **블루/그린 무중단 컷오버**로 **m7g.8xlarge(32 vCPU) → m7g.2xlarge(8 vCPU/32GiB)** 다운사이즈. AMI 백업 → 신규 인스턴스 기동·격리검증(/swagger 200·LimitNOFILE 1M) → ALB 타깃 합류(healthy) → 기존 디레지스터/드레이닝 → 스케줄러 단일화(항상 1개) → 구 인스턴스 stop(롤백 보험). **다운타임 0 · 5xx 0 · 지연 ~5ms.**
- 효과: 약 **$1,060/mo → $265/mo (~75%, 연 ~$9,540 절감, On-Demand 근사치)**. RAM 실사용 ~1.8Gi라 비제약.
- 구체 instance-id/IP·AMI·롤백 절차는 로컬 보관(본 문서 정책): 메모리 `project_livere_backend_rightsize`, 계획서 `~/.claude/plans/`. SSH는 `ssh livere-prod`(신규)·`ssh livere-prod-blue-old`(구, 롤백용).
- **다음(보류)**: 2xlarge에서 1~2주 실측 후 업무시간 피크 ≤25%(배치 윈도우 포함)면 동일 무중단 절차로 m7g.xlarge(4 vCPU, ~$132/mo) 트림.

### ② ALB WAF (중기, 신규 — 현재 prod ALB에 WAF 미연결)
- WAFv2 Web ACL 신규 → prod ALB 연결. 룰: ⓐ AWS 관리룰(Common + KnownBadInputs) ⓑ IP 레이트리밋(예 2,000 req/5min) ⓒ 스팸 Origin/Host 정규식 차단(tristateintel.blog·nursingstate.blog 계열).
- **반드시 COUNT 모드 1~2일 관측 → 오탐 확인 → BLOCK 전환.** 비용 저렴(~$5/ACL + $1/룰 + $0.6/백만요청).
- ⚠️ 한계: WAF는 **이번 근본원인(내부 마이그레이션 배치 폭주)은 못 막음** — 외부 스팸-오리진 보완책. 과신 금지.

### ③ spam-origin 정규식 자동학습 (장기)
- api 로그 "Origin not allowed"를 등록가능도메인(eTLD+1)별 집계 → 랜덤 서브도메인 다수·매칭 클라이언트 없음·버스트로 스코어링 → denylist 자동 제안 → WAF/api 피드. codeofnature식 일배치, **사람 승인 후 enforce**(observe 철학).
