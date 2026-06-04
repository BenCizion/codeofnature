---
aliases:
  - 라이브리 운영 매뉴얼 개정
  - 라이브리 장애 대처 개정안
  - livere ops manual revision
tags:
  - ops
  - manual
  - livere
  - incident
created: 2026-06-04
updated: 2026-06-04
related: "[[livere-incident-runbook]]"
---

# 운영 매뉴얼 개정 제안 — "주요 장애 별 대처" (라이브리 v.11)

> [!info] 목적
> 2026-06-04 운영 위젯 장애에서 드러난 **현행 매뉴얼의 오진 유발 요소**를 바로잡는 개정안. 신임 CTO 인수인계 및 운영 매뉴얼(Confluence "Jady - Draft" / Drive `1.4. 운영 매뉴얼`) 반영용.

## 배경 (왜 고치는가)
2026-06-04 위젯 장애 때 현행 매뉴얼대로 **DB 부하를 의심하고 RDS까지 재시작**했으나, 실측 결과:
- **RDS는 정상** — CPU ~3%, FreeableMemory ~22GB, 커넥션 미포화. **병목 아님.**
- **백엔드 EC2 CPU가 95~99%로 포화** — 이게 진짜 원인.
- EC2 인스턴스 리부트 후 `livere-api-prod`가 systemd **`disabled`** 라 자동 기동되지 않아 **완전 다운 위험** 발생.
- **근본 원인(이정대 CTO)**: 이전 **배치 작업의 CPU 폭주.**

즉 현행 매뉴얼의 "원인 = DB 부하" 가정과 "바로 재시작" 절차가 **오진·불필요한 RDS 재시작(전체 다운 리스크)**으로 이어졌다.

## 현행 (AS-IS)
> **livere v.11 위젯 이용 장애**
> - 현상: 반응 느림, 위젯 자체가 보이지 않음
> - 원인: 트래픽에 따른 DB 부하가 주로 원인 가능성
> - 대응:
>   1. Livere Main Backend(EC2) 모니터링 및 재시작
>   2. Livere Main DB(RDS) 모니터링 및 재시작
>   3. 해소 안 될 시 스케일 업

**문제점**
1. **원인 가정이 DB로 치우침** → 실제 1순위는 백엔드 EC2 CPU.
2. **"측정" 단계 부재** → 지표 확인 없이 바로 재시작으로 직행. (RDS 재시작은 전체 다운/페일오버 리스크)
3. **EC2 리부트 후 서비스 수동 기동 누락** → api/scheduler `disabled`라 리부트 시 자동 복구 안 됨.

## 개정안 (TO-BE)
> **livere v.11 위젯 이용 장애**
> - **현상**: 반응 느림 / 위젯이 보이지 않음
> - **원인 (빈도순)**: ① 백엔드 EC2 CPU 포화(배치 작업·트래픽·런어웨이) ② 백엔드 서비스 미기동(리부트 후 `disabled`) ③ (드묾) DB 부하
> - **대응 — 측정 먼저, 그 다음 조치**
>   1. **측정**: 백엔드 EC2 CPU → RDS 지표 순으로 CloudWatch 확인. (명령은 런북 §1 참조)
>      - EC2 CPU 90%+ 지속 → 백엔드가 원인. RDS는 보통 정상.
>   2. **백엔드 확인·복구**: `ssh livere-prod` 로 `top`·서비스 상태 확인.
>      - 범인이 **배치/scheduler** → 해당 배치 **중단/스케줄 조정** (재시작·리부트 불필요).
>      - 서비스가 `inactive` → **`sudo systemctl start livere-api-prod livere-scheduler-prod`** (리부트했으면 필수).
>   3. **RDS 재시작은 최후의 수단** — §1 측정에서 **DB 지표 포화가 확인됐을 때만.** (전체 다운/페일오버 + 콜드캐시)
>   4. **그래도 부하가 진짜면 스케일** — 백엔드 스케일아웃/업 우선, DB 스케일업은 그다음.
> - **주의(필수)**: EC2 인스턴스를 리부트하면 `livere-api-prod`/`livere-scheduler-prod`가 **자동 기동되지 않는다**(`disabled`). 리부트 후 반드시 **수동 start**. → 항구 대책으로 `systemctl enable` 적용 권장.

## 함께 반영할 개선 (백로그)
- [ ] `livere-api-prod`·`livere-scheduler-prod` **`enable`** (리부트 자동 복구).
- [ ] **배치 작업을 운영 백엔드와 분리** 또는 저트래픽 시간대 + CPU 제한.
- [ ] 백엔드 **CPU/load CloudWatch 알람** 임계치 설정.

---
상세 진단·복구 명령 전체는 **[[livere-incident-runbook]]** (`docs/livere-incident-runbook.md`) 참조.
