# LiveRe E2E 테스터 (댓글창 렌더 + 로그인 진입, 크로스 환경)

실제 고객사 페이지를 **브라우저·디바이스 매트릭스**로 열어 ① 댓글 위젯이 뜨는지 ② 로그인이 정상 진입하는지 자동 검증한다. **백엔드만 보던 livere-watch가 못 잡는 "로그인/렌더" 회귀**(이번 Keycloak 로그인 장애 같은)를 잡기 위함.

## 왜 필요한가 (이번 장애)
- 증상이 **환경별로 달랐다**: iOS Safari = 로그인 클릭시 무한 리프레시, iOS Chrome = 무반응, 사이트별 차이(오마이뉴스 O / 서울·국민 X).
- 백엔드/5XX 알람은 조용 → 기존 감시로는 미탐지. **엔진·디바이스별 실제 로그인 플로우**를 찍어야 잡힌다.

## 환경 매트릭스 (= 사용자 환경 목록 매핑)
| 프로젝트 | 엔진 | 대응 환경 |
|---|---|---|
| `pc-chrome` | Chromium | PC Windows/Mac Chrome |
| `pc-firefox` | Firefox | PC Firefox |
| `pc-safari` | WebKit | Mac Safari |
| `mobile-ios-safari` | WebKit (iPhone 14) | iOS Safari/Chrome(둘 다 WebKit) |
| `mobile-android-chrome` | Chromium (Pixel 7) | Android Chrome |

> 엔진은 OS 비의존 빌드라, **"진짜 Windows vs Mac / 실기기 iOS·Android"**까지 보려면:
> (a) 이 스위트를 각 OS 머신에서 실행, 또는 (b) **BrowserStack/SauceStack 연동**(Playwright 지원). → 확장 섹션 참고.

## 검사 항목
- **widget.spec** — 메인+iframe 전부 뒤져 댓글 위젯 컨테이너가 보이는지.
- **login.spec** — 로그인 버튼 클릭 후 결과를 분류(자격증명 불필요):
  - `OK` = 팝업/리다이렉트로 인증 IdP(Keycloak/소셜) 진입
  - `NO_RESPONSE` = 클릭해도 네비/팝업 없음 ← **이번 Chrome 무반응**
  - `REDIRECT_LOOP` = 메인 프레임 반복 네비게이션 ← **이번 Safari 무한 리프레시**

## 설치 (맥/PC)
```bash
cd ops/livere-e2e
npm install
npx playwright install --with-deps      # 브라우저 엔진 설치(최초 1회)
```

## 설정 (필수) — sites.json
1. **대상 URL**: `sites[].url` 을 댓글 위젯이 있는 **실제 기사 페이지**로. (현장 검증된 ohmynews/seoulshinmun/kmib 우선)
2. **셀렉터 확인**: 맥에서 그 페이지 DOM 검사해 `widgetSelectors` / `loginButtonText` 가 실제와 맞는지 보강(위젯이 iframe 안이면 그대로도 탐색됨).
3. `authDomains` 는 로그인 클릭시 진입해야 할 IdP 도메인 목록(Keycloak/네이버/카카오/구글 등).

## 실행
```bash
npm test                 # 전체 매트릭스
npx playwright test --project=mobile-ios-safari        # 특정 환경만
npx playwright test login.spec.ts --project=pc-safari  # 로그인만, Safari만
npm run run              # 실행 + Slack 매트릭스 보고(run.sh)
```
- 결과 리포트: `results/html/index.html`(스크린샷·trace·video 포함), `results/results.json`
- **Slack 보고**: `run.sh` 가 `../livere-watch/config.env` 의 `SLACK_WEBHOOK_URL` 재사용 → 환경×테스트 매트릭스(✅/❌/➖) + 실패 상세 전송.

## livere-watch 연동(선택)
- 주기 실행: launchd 작업 추가해 예: 10분마다 `bash ops/livere-e2e/run.sh login.spec.ts`.
- 그러면 **로그인 회귀가 사용자보다 먼저** Slack에 뜬다(이번 같은 건 즉시 포착).

## 실 OS·실기기 확장 (Phase 2)
- **BrowserStack**: `@playwright/test` + BrowserStack SDK 로 실제 Windows/맥/iPhone/안드 단말 매트릭스. config 에 remote 프로젝트 추가.
- 또는 Windows 러너 1대에서 이 스위트를 그대로 실행 → 진짜 Windows 렌더 커버.

## 한계/주의
- 셀렉터/URL 은 환경마다 다르니 **sites.json 보강 필수**(첫 실행시 NO_LOGIN_BUTTON 나오면 셀렉터부터).
- 소셜 로그인 "끝까지" 자동 로그인은 계정·2FA 때문에 기본 미포함(진입 도달까지만 검증). 필요시 테스트 전용 계정으로 1개 provider 풀플로우 추가 가능.
- 이 컨테이너(원격)엔 브라우저가 없어 여기선 못 돌림 → **맥/PC에서 실행**.
