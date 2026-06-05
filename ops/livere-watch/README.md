# LiveRe 24/7 감시 시스템 (`livere-watch`)

상시 가동 맥에서 CloudWatch 알람을 폴링 → 감지 시 **결정적(deterministic) 읽기전용 진단 수집** → **Claude는 그 텍스트만 해석·분류**(도구 없음) → **Slack 보고**. 자동 prod-write는 **기본 OFF**(`observe`).

> 정본 런북: [`docs/livere-incident-runbook.md`](../../docs/livere-incident-runbook.md) · 매뉴얼 개정안: [`docs/livere-ops-manual-revision.md`](../../docs/livere-ops-manual-revision.md)

## 안전 설계 (핵심)
- **Claude는 프로덕션 실행 권한이 없다.** `collect.sh`(셸)가 읽기전용 진단만 모으고, Claude는 `--allowedTools ""` 로 호출돼 **명령 실행이 불가**. 텍스트 해석·분류만 한다. → "무인 자율 무제한 Bash on prod" 구조 없음.
- **프로덕션을 바꾸는 코드는 단 하나** — `lib.sh:remediate_restart_api`(고정 명령 `systemctl start`, 서킷브레이커·감사로그). 그리고 **기본값 `AUTONOMY=observe` 에서는 절대 실행되지 않는다**(승인 요청만).
- 자동 재기동을 켜려면 운영자가 **의식적으로 `config.env`의 `AUTONOMY=safe`** 로 바꿔야 한다.

## 동작 구조
```
CloudWatch 알람(ALARM)
   └─(launchd 60초 폴링) watch.sh
        ├─ Slack: "장애 감지"
        ├─ collect.sh  (셸, 읽기전용: ssh 상태/top/log, ALB 헬스, RDS/EC2 지표)
        ├─ claude -p --allowedTools ""  (도구 없음 → 텍스트 해석만) → 리포트 + DECISION
        ├─ Slack: 진단 리포트
        └─ 가드레일:
             observe(기본): 자동 조치 없음 → 권고/승인요청만
             safe:          DECISION:SAFE_RESTART_API + 서킷브레이커 OK → systemctl start (유일 자동)
             위험(배치중단/스케일/리부트/RDS): 항상 Slack 승인요청만
   (알람 해제시) Slack: "복구"
```

## 사전 요구
- macOS, `aws` CLI(프로파일 `cizion-new`), `ssh` 호스트 alias `livere-prod`, `python3`, `curl`
- **Claude Code CLI**(`claude`) 설치 + 로그인
- 이 레포 클론(런북 경로), Slack Incoming Webhook URL

## 설치
```bash
cd ops/livere-watch
cp config.env.example config.env      # 값 채우기 (특히 SLACK_WEBHOOK_URL). 기본 AUTONOMY=observe
$EDITOR config.env
./install.sh                          # 의존성 확인 + 절대경로 주입 + launchd 등록 + Slack 테스트
```
중지/제거: `./uninstall.sh`

## Slack Webhook 만들기
1. https://api.slack.com/apps → Create New App → From scratch
2. **Incoming Webhooks** 켜기 → *Add New Webhook to Workspace* → 채널 선택
3. `https://hooks.slack.com/services/...` 를 `config.env` 의 `SLACK_WEBHOOK_URL` 에 입력

## 자율도 (`AUTONOMY`)
| 값 | 동작 |
|---|---|
| `observe` (기본) | **자동 prod-write 없음.** 진단·알림·승인요청만. |
| `safe` | 위 + **죽은 api 자동 재기동만**(서킷브레이커). 나머지는 승인. *의식적으로 켜기.* |
| `aggressive` | (향후) 안전조치 + 배치중단까지. 리부트·RDS 는 항상 승인. |

## CloudWatch 알람 보강 (1회 권장)
"늦게 뜸"(지연) 선제 감지 + 워처 생존 감시:
```bash
source ./config.env
AWS=(aws --profile "$AWS_PROFILE" --region "$AWS_REGION")
# 워처 데드맨 스위치(하트비트 5분 끊기면 ALARM)
"${AWS[@]}" cloudwatch put-metric-alarm --alarm-name Livere_Watch_Heartbeat_Missing \
  --namespace LivereWatch --metric-name WatcherHeartbeat --statistic Sum \
  --period 300 --evaluation-periods 1 --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching --alarm-actions <SNS_TOPIC_ARN>
# ALB p95 지연 알람 등은 TargetGroup/LB 차원값 채워 추가.
```
> 알람 이름이 `ALARM_PREFIX`(기본 `Livere`) 로 시작해야 폴링에 잡힘.

## 추가 하드닝 (운영 권장)
- **최소권한 IAM**: 감시 전용(CloudWatch/ELB/EC2/RDS describe 읽기). 어드민 키 금지.
- **읽기전용 SSH**: bastion `authorized_keys` 의 `command=`(forced-command)로 진단 명령만 허용하는 별도 키. 재기동(`safe`)은 분리된 명시 경로.
- `config.env` 는 `.gitignore` 처리(웹훅/토큰 커밋 금지). 모든 조치는 `~/.livere-watch/watch.log` 에 감사 기록.

## 모듈 (launchd 작업)
| 작업 | 주기 | 역할 |
|---|---|---|
| `watch.sh` | 60초 | CloudWatch 알람 폴링 → 진단/심각도/가드레일 |
| `canary.sh` | 1시간 | 위젯/댓글 API 실제 호출 → 정상출력·응답시간 → 심각도 Slack |
| `email_poll.sh` | 3분(선택) | dev@cizion.com CloudWatch ALARM 이메일 독립 수신 → 같은 파이프라인 |
| `caffeinate` | 상주 | 맥 잠자기 억제(전력설정 보험) |

## 심각도 1~10 (Slack)
모든 알림 헤더에 직관적 막대 표시 — 예: `심각도 8/10 [████████░░] 🟧 심각`.
사용량(EC2 CPU)·지연·5XX·캐너리 실패가 높을수록 ↑, **서비스 다운/사용량 초과 = 9~10**. 기준값은 `lib.sh:compute_severity` / `canary.sh` 에 있으며 **잠정(추후 검토)**.

## 상시 맥 설치·전력설정·인계
→ [`HANDOFF.md`](HANDOFF.md) 참조 (pmset 전력설정 + 다른 맥 Claude 킥오프 프롬프트).

## 확장 로드맵
- ALB 지연 알람 + CloudWatch Synthetics 캐너리(브라우저 렌더 검증)
- 승인형 조치를 Slack 인터랙티브 버튼으로
- 인시던트 자동 기록 → 런북 §6 커밋
