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
| Prod 백엔드 EC2 | `i-0d311a516c68ea6a2` (사설 `10.0.147.210`) |
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
