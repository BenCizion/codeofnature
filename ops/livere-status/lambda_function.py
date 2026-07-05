import json, os, time, urllib.request, urllib.error, urllib.parse, datetime
from concurrent.futures import ThreadPoolExecutor

import boto3

BUCKET = "livere-com-web"
KEY = "status.json"
UA = "Mozilla/5.0 (compatible; LiveRe-StatusProber/1.0; +https://www.livere.com/status)"

# Internal (Cizion-only) detailed status. Published to a separate, IP-restricted
# bucket so per-outlet + auth-path detail is not exposed on the public page.
# Skipped entirely unless INTERNAL_BUCKET env is set (dormant until provisioned).
INTERNAL_BUCKET = os.environ.get("INTERNAL_BUCKET")
INTERNAL_KEY = os.environ.get("INTERNAL_KEY", "status-internal.json")

# tier 1=critical, 2=core, 3=legacy. degraded if 200 but slow.
SERVICES = [
    # widget-hash returns HTTP 200 even for a nonexistent client (global hash +
    # client:null). body_check confirms the real client resolved, so a broken
    # client lookup surfaces as down instead of a false operational.
    {"key": "comment-api", "tier": 1, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "댓글 API", "en": "Comment API", "zh": "评论 API"},
     "url": "https://api.livere.org/api/v2/widget-hash?client_id=9TdXiy9Vk9NTePPebJYP",
     "body_check": {"path": ["data", "client", "id"], "equals": "9TdXiy9Vk9NTePPebJYP"}},
    {"key": "widget-cdn", "tier": 1, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "위젯 CDN", "en": "Widget CDN", "zh": "挂件 CDN"},
     "url": "https://cdn-city.livere.com/js/embed.dist.js"},
    # cdn.livere.com — separate v9 widget CDN (rehosted to new account 2026-07-06,
    # E2ATQ74UMIBW9V). Distinct from cdn-city; press outlets embed v9 widget bundles
    # (livere8_lib.js / embed.dist.js) directly. Verify byte-serving is alive.
    {"key": "widget-cdn-livere", "tier": 1, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "위젯 CDN(livere.com)", "en": "Widget CDN (livere.com)", "zh": "挂件 CDN (livere.com)"},
     "url": "https://cdn.livere.com/LiveReX/tower/js/embed.dist.js"},
    {"key": "keycloak", "tier": 1, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "인증(Keycloak)", "en": "Auth (Keycloak)", "zh": "认证 (Keycloak)"},
     "url": "https://vault.livere.org/realms/livere/.well-known/openid-configuration"},
    {"key": "admin", "tier": 2, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "관리자", "en": "Admin", "zh": "管理后台"},
     "url": "https://admin.livere.org/"},
    {"key": "connect-api", "tier": 2, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "Connect API(유료)", "en": "Connect API", "zh": "Connect API"},
     "url": "https://connect.livere.org/swagger/index.html"},
    {"key": "dotcom", "tier": 2, "expect": 200, "degradedMs": 1500,
     "name": {"ko": "닷컴 웹사이트", "en": "Website", "zh": "官网"},
     "url": "https://www.livere.com/"},
    {"key": "passport", "tier": 3, "expect": 200, "degradedMs": 3000,
     "name": {"ko": "v9 로그인 게이트웨이", "en": "v9 Login Gateway", "zh": "v9 登录网关"},
     "url": "https://passport.livere.com/v1/login/city"},
    # v9 인사이트(premium.livere.com)는 서비스 종료(2026-07)되어 프로브에서 제거함.
]

# media-api count (api.livere.net) — the legacy per-article comment-count path
# that press outlets call server-side. This was the actual stage of the
# 2026-07-03 imaeil/newdaily outages, yet it was absent from the probes.
# It returns HTTP 200 even on auth failure (code:4010), so it MUST use body_check
# (code == 2000). Requires a dedicated canary api_key injected via env
# (MEDIAAPI_CANARY_KEY / MEDIAAPI_CANARY_SECRET) + a stable canary article referer
# (MEDIAAPI_CANARY_REFERER). Added only when the canary secret is configured, so
# the probe is dormant until the key exists (provisioned with the media-api
# new-account migration). Never hardcode the secret here.
if os.environ.get("MEDIAAPI_CANARY_KEY") and os.environ.get("MEDIAAPI_CANARY_REFERER"):
    SERVICES.append({
        "key": "count-api", "tier": 2, "expect": 200, "degradedMs": 2000,
        "name": {"ko": "댓글수 API(레거시)", "en": "Count API (legacy)", "zh": "评论数 API"},
        "url": "https://api.livere.net/v1/article/comments/count?referer="
               + urllib.parse.quote(os.environ["MEDIAAPI_CANARY_REFERER"], safe=""),
        "headers": {"x-auth-api-key": "${MEDIAAPI_CANARY_KEY}",
                    "x-auth-api-secret": "${MEDIAAPI_CANARY_SECRET}"},
        "body_check": {"path": ["code"], "equals": 2000},
    })


# Per-outlet probes for the INTERNAL dashboard only.
# ★grouped by ACTUAL API issuance (source of truth = DB), not SEQUENCE_MAP:
#   connect = Connect API issued  → client_operators (v11 Postgres livere_prod_client_operators)
#   count   = Count API issued     → api_key table active rows (new Aurora MySQL, isDeleted != 1)
#   seqmap  = mapped in SEQUENCE_MAP but NOT issued (monitoring only; count auth not active)
# Issuance verified 2026-07-05. See "발급 목록 조회처" note in index.html.
PRESS = [
    # --- Connect API 발급 (client_operators, 6) ---
    ("connect", "매일신문", "DaySVVN9L41lJd9Ck8gq"),
    ("connect", "문화체육관광부", "YdhARqKS103C4SL8qeKN"),
    ("connect", "MBN", "O4ORC1v5ljAl4d1bxoOJ"),
    ("connect", "법률신문", "QLiKCU5qv8CDsxN7L8uM"),
    ("connect", "연합뉴스", "XiWmxgYCT7Yewo6OsLTd"),
    ("connect", "메디게이트", "tw5l8dyPLpQifHKheDIS"),
    # --- Count API 발급 (api_key 활성, 5매체/6client. ★매일신문은 connect와 겸용) ---
    ("count", "매일신문(count)", "DaySVVN9L41lJd9Ck8gq"),
    ("count", "KBS", "fQYxQ5qp8GhnbOHQQZxR"),
    ("count", "서울신문", "7hh0CAc4Z8qVfui2RjRw"),
    ("count", "오마이뉴스", "F2IskXfsCLDY9wDSpjWP"),
    ("count", "뉴데일리", "LlwR0euOxEvgMKpHrBrv"),
    ("count", "뉴데일리경제", "SgrNakzo1Tap75hxkVfn"),
    # --- SEQUENCE_MAP 매핑이나 미발급 (모니터링만, count 인증 비활성) ---
    ("seqmap", "YTN", "I28LJpvdf1rofH2FBf3R"),
    ("seqmap", "뉴시스", "4aGqryBwlJh8UaW4Mijf"),
    ("seqmap", "국민일보", "nGumZZ5Yh7abZMAZIPKc"),
    ("seqmap", "뉴스1", "E0d5l2EzmlkOmhYuTXBp"),
    ("seqmap", "부산일보", "SH40WZ7dxthTB23WAPpT"),
    ("seqmap", "국제신문", "8e5Us6Mkg02kXoxX36dO"),
    ("seqmap", "쿠키뉴스", "677Z9hYtgBB5Mr1aemwG"),
    ("seqmap", "아시아투데이", "s8Hx22mrndyVGEcmqFF2"),
    ("seqmap", "뉴스웨이", "xvjt0SaqjsOVRFbAT80i"),
    ("seqmap", "브릿지경제", "g6dTP1AnmvqZXqoejVdq"),
    ("seqmap", "한경매거진", "oOxtCAgsvBEnhhT3UKJP"),
    ("seqmap", "전기신문", "9ldUeovnRvfa4Um2Bnpa"),
    ("seqmap", "경남신문", "QetGIwraq5YTwFiRUyUQ"),
    ("seqmap", "영남일보", "YkWR1ZwbtXJJ3jZNcbbU"),
]


def press_svc(group, name, cid):
    return {
        "key": "press:" + cid, "tier": 2, "expect": 200, "degradedMs": 2000,
        "name": {"ko": name, "en": name, "zh": name}, "group": group, "clientId": cid,
        "url": "https://api.livere.org/api/v2/widget-hash?client_id=" + cid,
        "body_check": {"path": ["data", "client", "id"], "equals": cid},
    }


# Set True after the first invocation in a container. On a COLD start the whole
# runtime (imports, first DNS/TLS) inflates latency ~2.5s for every probe, which
# would otherwise flash a false "degraded". On cold runs we only judge up/down
# (hard failures); latency-based degraded is deferred to the next (warm) run,
# which with rate(1min) scheduling is ~all runs.
_WARM = False


def _resolve_headers(raw):
    # Header values may reference an env var as "${NAME}" so secrets (canary API
    # keys) stay out of source. Unresolved refs drop the header (probe will fail
    # auth, surfacing the misconfig rather than sending a literal "${NAME}").
    out = {"User-Agent": UA}
    for k, v in (raw or {}).items():
        if isinstance(v, str) and v.startswith("${") and v.endswith("}"):
            val = os.environ.get(v[2:-1])
            if val:
                out[k] = val
        else:
            out[k] = v
    return out


def _dig(obj, path):
    for p in path:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(p)
    return obj


def probe(svc, cold):
    # body_check: {"path": [...], "equals": v} — for APIs that return a business
    # code inside an HTTP-200 body (media-api count gives {"code":2000} on success
    # but {"code":4010} on auth failure, both HTTP 200). Such services can't be
    # judged by httpCode alone; we parse the body and compare.
    url = svc["url"]
    body_check = svc.get("body_check")
    t0 = time.time()
    code = 0
    err = None
    body_bytes = b""
    try:
        req = urllib.request.Request(url, method="GET", headers=_resolve_headers(svc.get("headers")))
        with urllib.request.urlopen(req, timeout=8) as r:
            code = r.status
            body_bytes = r.read(65536 if body_check else 256)
    except urllib.error.HTTPError as e:
        code = e.code
        if body_check:
            try:
                body_bytes = e.read(65536)
            except Exception:
                pass
    except Exception as e:  # URLError, timeout, ssl, etc.
        err = type(e).__name__
    latency_ms = int((time.time() - t0) * 1000)

    body_ok = True
    body_detail = None
    if body_check and err is None:
        try:
            actual = _dig(json.loads(body_bytes.decode("utf-8", "replace")), body_check["path"])
            body_ok = (actual == body_check["equals"])
            if not body_ok:
                body_detail = "%s=%r" % (".".join(map(str, body_check["path"])), actual)
        except Exception as e:
            body_ok = False
            body_detail = "parse:" + type(e).__name__

    if err is not None or code == 0 or code != svc["expect"] or not body_ok:
        status = "down"
    elif not cold and latency_ms > svc["degradedMs"]:
        status = "degraded"
    else:
        status = "operational"

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "key": svc["key"], "name": svc["name"], "tier": svc["tier"],
        "status": status, "httpCode": code, "latencyMs": latency_ms,
        "checkedAt": now,
        # carry through outlet identity for press probes (used by internal doc)
        **({"group": svc["group"]} if "group" in svc else {}),
        **({"clientId": svc["clientId"]} if "clientId" in svc else {}),
        **({"cold": True} if cold else {}),
        **({"error": err} if err else {}),
        **({"bodyError": body_detail} if body_detail else {}),
    }


def overall_of(services):
    t1_down = any(s["tier"] == 1 and s["status"] == "down" for s in services)
    t2_down = any(s["tier"] == 2 and s["status"] == "down" for s in services)
    t3_down = any(s["tier"] == 3 and s["status"] == "down" for s in services)
    degraded = any(s["status"] == "degraded" for s in services)
    if t1_down:
        return "major_outage"
    if t2_down:
        return "partial_outage"
    if t3_down or degraded:
        return "degraded"
    return "operational"


def lambda_handler(event, context):
    global _WARM
    cold = not _WARM
    # Per-outlet probes run only when an internal bucket is configured (they add
    # ~19 requests). Public publish never depends on them.
    press_defs = [press_svc(*p) for p in PRESS] if INTERNAL_BUCKET else []
    with ThreadPoolExecutor(max_workers=12) as ex:
        services = list(ex.map(lambda s: probe(s, cold), SERVICES))
        press = list(ex.map(lambda s: probe(s, cold), press_defs))
    _WARM = True

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    journeys = [
        {"key": "login", "name": {"ko": "로그인", "en": "Login", "zh": "登录"}, "status": "unknown"},
        {"key": "comment-crud", "name": {"ko": "댓글 작성·삭제", "en": "Comment create/delete", "zh": "评论增删"}, "status": "unknown"},
    ]

    s3 = boto3.client("s3")

    # Public status.json — service level only (no per-outlet detail).
    doc = {
        "updatedAt": now, "overall": overall_of(services),
        "services": services, "journeys": journeys, "incidents": [],
    }
    body = json.dumps(doc, ensure_ascii=False).encode("utf-8")
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=body,
                  ContentType="application/json; charset=utf-8",
                  CacheControl="public, max-age=30")

    # Internal status-internal.json — services + per-outlet, richer detail.
    if INTERNAL_BUCKET:
        press_down = [p for p in press if p["status"] != "operational"]
        internal = {
            "updatedAt": now,
            "overall": overall_of(services),
            "services": services,
            "press": press,
            "pressSummary": {"total": len(press),
                             "operational": len(press) - len(press_down),
                             "down": len(press_down)},
            "journeys": journeys,
            "incidents": [],
        }
        ibody = json.dumps(internal, ensure_ascii=False).encode("utf-8")
        s3.put_object(Bucket=INTERNAL_BUCKET, Key=INTERNAL_KEY, Body=ibody,
                      ContentType="application/json; charset=utf-8",
                      CacheControl="public, max-age=30")

    return {"overall": doc["overall"], "bytes": len(body),
            "services": {s["key"]: s["status"] for s in services},
            "press": {p["clientId"]: p["status"] for p in press} if press else {}}
