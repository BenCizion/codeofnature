# livere-watch 인계 (상시 가동 맥북 설치용)

회사의 **24시간 가동 맥북**에서 이 감시 시스템을 설치·구동하기 위한 인계 문서.
운영자(사람)가 **전력 설정**을 먼저 하고, 그 맥의 **Claude Code에게 아래 "킥오프 프롬프트"를 붙여넣어** 설치를 맡긴다.

> 현재 단계 = **긴급 대응 가능 수준.** 자동 prod-write 는 OFF(`AUTONOMY=observe`), 심각도/알람 기준값은 잠정(추후 검토).

---

## 1) 전력·화면 설정 (맥이 꺼지지 않게) — 사람이 먼저 실행
AC 전원 연결 상태에서 터미널에 입력(관리자 비번 물음):
```bash
sudo pmset -c sleep 0          # 시스템 잠자기 안 함(가장 중요)
sudo pmset -c disksleep 0      # 디스크 안 재움
sudo pmset -c displaysleep 10  # 화면만 10분 후 off (시스템은 계속 가동 → 워처 영향 없음)
sudo pmset -c powernap 0
sudo pmset -c autorestart 1    # 정전 복구 시 자동 부팅
sudo pmset -g custom           # 확인
```
- **화면(밝기/displaysleep)은 워처 동작과 무관** — 화면이 꺼지거나 밝기를 최소로 낮춰도 백그라운드 감시는 계속됩니다. 번인 방지를 위해 밝기 낮춤 또는 `displaysleep 10` 권장.
- **뚜껑(클램셸)**: 노트북 뚜껑을 닫으면 기본적으로 잠듭니다. → ① 뚜껑 열어두기, 또는 ② 외장 모니터+전원+키보드/마우스 연결 시 클램셸 모드로 닫아도 가동. 추가 보험으로 설치 시 `caffeinate` 데몬이 함께 등록됩니다.
- macOS 자동 업데이트로 인한 재부팅을 막으려면 시스템 설정에서 자동 재시작 끄기 권장(`autorestart 1`은 정전 복구용).

---

## 2) Claude Code 킥오프 프롬프트 (그 맥의 Claude에게 그대로 붙여넣기)

````text
너는 회사 상시 가동 맥북에서 LiveRe 프로덕션 24/7 감시 시스템(livere-watch)을 설치·구동하는 역할이다.
이 맥은 로컬 자격을 가진다: AWS 프로파일 cizion-new(ap-northeast-2), SSH alias livere-prod, claude CLI 로그인됨.

## 컨텍스트
- 레포: BenCizion/codeofnature, 브랜치 claude/livery-prod-outage-g7YZz
- 감시 코드: ops/livere-watch/  (먼저 README.md 와 이 파일 HANDOFF.md 정독)
- 정본 런북: docs/livere-incident-runbook.md
- 설계 원칙(반드시 유지): Claude는 prod 실행권한 없음(읽기전용 해석만), 자동 prod-write 기본 OFF(AUTONOMY=observe). 위험조치는 Slack 승인만.

## 할 일
1. 레포 클론 위치 확인(`find ~ -type d -name codeofnature`). 없으면 클론. 해당 브랜치 checkout + `git pull`.
2. `cd ops/livere-watch && cp config.env.example config.env`
3. config.env 채우기 — 운영자에게 다음 값을 물어서 입력:
   - SLACK_WEBHOOK_URL (필수)
   - REPO_DIR (이 클론 절대경로)
   - CANARY_WIDGET_JS_URL / CANARY_API_HEALTH_URL / CANARY_COMMENTS_URL (실 위젯·댓글 출력 점검 URL)
   - (선택) EMAIL_APP_PASSWORD: dev@cizion.com 의 Google 앱 비밀번호. 넣으면 CloudWatch 알람 이메일도 독립 수신.
   - AUTONOMY 은 지금은 observe 유지(자동 재기동 OFF).
4. `./install.sh` 실행 → Slack에 "설치 완료" 테스트 메시지 도착 확인.
5. `launchctl list | grep livere` 로 watch(60s)/canary(1h)[/email(3m)]/caffeinate 등록 확인.
6. README "CloudWatch 알람 보강"의 데드맨 하트비트 알람을 1회 생성(SNS ARN 필요).
7. 운영자에게 보고: 무엇이 켜졌는지, 심각도 1~10 Slack 표시 예시, 다음 검토거리(알람 기준값/하드닝/AUTONOMY=safe 전환).

## 금지/주의
- AUTONOMY 을 임의로 safe/aggressive 로 바꾸지 마라(운영자 명시 승인 필요).
- 프로덕션에 직접 재시작/스케일/리부트/RDS 변경을 하지 마라. 감시·알림·설치만.
- config.env(시크릿)는 절대 커밋하지 마라(.gitignore 처리됨).
````

---

## 3) 설치 후 동작 요약 (운영자 확인용)
- **알람 감지**: CloudWatch 알람 폴링(60초) + (선택) dev@cizion.com 이메일 수신(3분). 둘 다 같은 진단 파이프라인.
- **진단**: 셸이 읽기전용 수집 → Claude가 텍스트만 해석 → Slack에 **심각도 1~10 막대**와 리포트.
- **캐너리**: 1시간마다 위젯/댓글 API를 실제 호출해 정상출력·응답시간 점검 → 이상시 Slack(심각도 포함).
- **조치**: 기본 observe = 알림·승인요청만. (추후 검토 후 `AUTONOMY=safe` 로 죽은 api 자동 재기동만 허용 가능.)
- **심각도 예**: `심각도 8/10 [████████░░] 🟧 심각`, 사용량/지연/실패가 높을수록 ↑, 서비스 다운·사용량 초과 = 9~10.
