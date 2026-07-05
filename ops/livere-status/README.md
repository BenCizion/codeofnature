# LiveRe 공개 상태 페이지 — 서버사이드 프로버 (`livere-status`)

`https://www.livere.com/status` 공개 상태 페이지의 **데이터 소스**. AWS Lambda가 1분마다 전 서비스를 GET 프로브해 `status.json`을 S3에 발행하고, 정적 닷컴 페이지가 **동일 출처**로 그걸 읽어 렌더한다. (브라우저 CORS 때문에 페이지가 직접 크로스오리진 프로브를 못 하므로 서버사이드 프로버가 필요.)

```
EventBridge rate(1분) → Lambda(livere-status-prober) → 8개 서비스 GET → status.json
   → s3://livere-com-web/status.json (Cache-Control: max-age=30)
   → https://www.livere.com/status.json  (CloudFront 30초 캐시, 페이지와 동일 출처)
```

## AWS 자원 (account 360055708600 `cizion-new`, ap-northeast-2)
- Lambda: `livere-status-prober` (python3.12, arm64, 128MB, timeout 30s)
- IAM role: `livere-status-prober-role` (최소권한: `s3:PutObject` on `livere-com-web/status.json` + logs)
- EventBridge rule: `livere-status-prober-1min` (`rate(1 minute)`, ENABLED)
- 발행 대상: `s3://livere-com-web/status.json` (닷컴 사이트와 같은 버킷=동일 출처)
- **CloudFront 변경 없음**: 배포 `E1LUNSEOGIOOJM` 기본정책 Managed-CachingOptimized가 오리진 `Cache-Control` 존중(MinTTL=1) → max-age=30 그대로 30초 캐시. CF function `livere-com-apex-redirect`은 `/status.json` 통과(OLD 맵에 없음, www 호스트는 미리다이렉트).

## status.json 스키마 (닷컴 세션과의 계약)
`updatedAt`, `overall`(operational|degraded|partial_outage|major_outage), `services[]`(key, name{ko,en,zh}, tier(1~3), status(operational|degraded|down), httpCode, latencyMs, checkedAt), `journeys[]`(Phase2, 현재 login·comment-crud=unknown 자리), `incidents[]`.
- overall 산식: tier1 down=major / tier2 down=partial / tier3 down·degraded=degraded / else operational.
- **콜드스타트 가드**: 콜드 실행(컨테이너 첫 호출)은 런타임 init로 latency가 ~2.5s 부풀어 가짜 degraded가 뜨므로, 콜드 때는 하드 실패(non-200/timeout)만 down 판정하고 latency 기반 degraded는 다음 웜 실행으로 미룬다(rate 1분이라 사실상 항상 웜).

## 프로브 대상 (8개 + 카나리 시 count-api)
tier1: comment-api(api.livere.org widget-hash) · widget-cdn(cdn-city embed.dist.js) · keycloak(vault .well-known)
tier2: admin(/) · connect-api(swagger) · dotcom(www /)
tier3: passport(/v1/login/city) · insight(premium /)
> 백엔드에 /health 없음 → swagger·widget-hash를 카나리로 사용.

## ★body_check — HTTP 200에 숨은 실패 판정 (2026-07-03 추가)
일부 API는 **인증/오류를 HTTP 200 body 안의 code로 반환**해서 httpCode만으론 오판한다.
2026-07-03 매일신문·뉴데일리 count 장애가 정확히 이 케이스(media-api가 `code:4010` 인증실패도 HTTP 200).
- `svc["body_check"] = {"path": ["code"], "equals": 2000}` → body JSON의 해당 경로 값이 일치해야 operational, 아니면 down.
- `svc["headers"] = {"x-auth-api-key": "${ENV_NAME}"}` → 값이 `${NAME}`이면 env에서 치환(시크릿 미하드코딩). 미해결 시 헤더 드롭(인증실패로 표면화).
- body_check 있으면 body 최대 64KB 읽어 파싱, 없으면 기존처럼 256B만(기존 8개 무영향).
- **comment-api 강화**: widget-hash는 없는 client도 200+글로벌hash 반환 → body_check `data.client.id`로 실제 client 확인(죽은 client lookup을 down으로 잡음).

## count-api(media-api, api.livere.net) 프로브 — 카나리 키 의존, 조건부 활성
레거시 언론사 서버사이드 댓글수 경로. 이번 장애의 실제 무대인데 기존 프로브에 없었음.
- **env `MEDIAAPI_CANARY_KEY`/`MEDIAAPI_CANARY_SECRET`/`MEDIAAPI_CANARY_REFERER`가 있을 때만 SERVICES에 추가**(없으면 dormant). 전용 카나리 api_key 발급은 media-api 신계정 마이그레이션과 함께(오늘 밤).
- body_check `code==2000`. CloudFront count 캐시(referer키 TTL30분) 있으나 카나리는 code만 보면 됨.
- ★Lambda 배포 시 env 3개를 함수 환경변수(또는 SSM)로 주입. 시크릿은 코드에 절대 안 넣음.

## 배포 / 갱신
```bash
export AWS_PROFILE=cizion-new AWS_REGION=ap-northeast-2
cd ops/livere-status
zip -q -r function.zip lambda_function.py
aws lambda update-function-code --function-name livere-status-prober --zip-file fileb://function.zip
aws lambda wait function-updated --function-name livere-status-prober
# 수동 테스트
aws lambda invoke --function-name livere-status-prober --payload '{}' /tmp/out.json && cat /tmp/out.json
curl -s "https://www.livere.com/status.json?cb=$RANDOM" | python3 -m json.tool
```

## 폐기 (teardown)
```bash
aws events remove-targets --rule livere-status-prober-1min --ids 1
aws events delete-rule --name livere-status-prober-1min
aws lambda delete-function --function-name livere-status-prober
aws iam delete-role-policy --role-name livere-status-prober-role --policy-name livere-status-prober-perm
aws iam delete-role --role-name livere-status-prober-role
aws s3 rm s3://livere-com-web/status.json
```

## 상호보완 (다른 ops 자산)
- `../livere-watch`: CloudWatch 알람 폴링 + 시간당 canary + Slack 알림/자동 재기동 → **내부 운영 알림**. (맥 상주 의존)
- `../livere-e2e`: Playwright 로그인/렌더 회귀 → **Phase2에서 journeys 채움**(결과를 status.json journeys로 발행).
- 이 프로버는 **공개 페이지 전용**이라 맥 무관(클라우드 상시).

## 닷컴(정적 페이지) 측
핸드오프: `~/livere-com-web/docs/STATUS_PAGE_HANDOFF.md`. Phase1 = `src/pages/[lang]/status.astro`가 `/status.json` 소비.
