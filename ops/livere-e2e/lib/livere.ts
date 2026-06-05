import { readFileSync } from 'fs';
import path from 'path';
import type { Page, BrowserContext, Frame, Locator } from '@playwright/test';

export type SiteCfg = {
  widgetSelectors: string[];
  loginButtonText: string[];
  authDomains: string[];
  sites: { name: string; url: string; expect?: string }[];
};

export function loadCfg(): SiteCfg {
  return JSON.parse(readFileSync(path.resolve(process.cwd(), 'sites.json'), 'utf8'));
}

function allFrames(page: Page): Frame[] {
  return [page.mainFrame(), ...page.frames().filter((f) => f !== page.mainFrame())];
}

/** 댓글 위젯이 렌더됐는지(메인+iframe 전부 탐색). 첫 매칭 반환. */
export async function findWidget(page: Page, cfg: SiteCfg): Promise<{ frame: Frame; selector: string } | null> {
  for (const frame of allFrames(page)) {
    for (const sel of cfg.widgetSelectors) {
      const loc = frame.locator(sel).first();
      if ((await loc.count().catch(() => 0)) > 0 && (await loc.isVisible().catch(() => false))) {
        return { frame, selector: sel };
      }
    }
  }
  return null;
}

/** 로그인 버튼(메인+iframe 텍스트 탐색). */
export async function findLoginButton(page: Page, cfg: SiteCfg): Promise<Locator | null> {
  for (const frame of allFrames(page)) {
    for (const t of cfg.loginButtonText) {
      const loc = frame.getByText(new RegExp(`^\\s*${t}\\s*$`, 'i')).first();
      if ((await loc.count().catch(() => 0)) > 0 && (await loc.isVisible().catch(() => false))) return loc;
    }
    // 텍스트가 버튼 안에 감싸진 경우 role 기반 폴백
    for (const t of cfg.loginButtonText) {
      const loc = frame.getByRole('button', { name: new RegExp(t, 'i') }).first();
      if ((await loc.count().catch(() => 0)) > 0 && (await loc.isVisible().catch(() => false))) return loc;
    }
  }
  return null;
}

export type LoginResult = {
  status: 'OK' | 'NO_RESPONSE' | 'REDIRECT_LOOP' | 'NO_LOGIN_BUTTON' | 'UNKNOWN';
  detail: string;
};

/**
 * 로그인 버튼 클릭 후 결과를 분류.
 *  - OK           : 팝업/리다이렉트로 인증 IdP(Keycloak/소셜) 진입
 *  - NO_RESPONSE  : 클릭해도 네비게이션/팝업 없음 (관찰: Chrome 무반응)
 *  - REDIRECT_LOOP: 메인 프레임이 임계치 이상 반복 네비게이션 (관찰: Safari 무한 리프레시)
 * 자격증명 없이 "로그인 진입 가능 여부"만 판정 → 이번 회귀 증상 그대로 탐지.
 */
export async function classifyLogin(page: Page, context: BrowserContext, cfg: SiteCfg): Promise<LoginResult> {
  const btn = await findLoginButton(page, cfg);
  if (!btn) return { status: 'NO_LOGIN_BUTTON', detail: '로그인 버튼을 찾지 못함(셀렉터 확인 필요)' };

  let navCount = 0;
  const onNav = (frame: Frame) => { if (frame === page.mainFrame()) navCount++; };
  page.on('framenavigated', onNav);

  const popupPromise = context.waitForEvent('page', { timeout: 9000 }).catch(() => null);
  await btn.click({ timeout: 8000 }).catch(() => {});
  const popup = await popupPromise;
  await page.waitForTimeout(8000); // 루프/지연 관찰 창
  page.off('framenavigated', onNav);

  const target = popup ?? page;
  const url = (() => { try { return target.url(); } catch { return ''; } })();
  const onAuth = cfg.authDomains.some((d) => url.includes(d));

  if (popup) return { status: 'OK', detail: `popup→${url}` };
  if (onAuth && navCount < 6) return { status: 'OK', detail: `redirect→${url}` };
  if (navCount >= 6) return { status: 'REDIRECT_LOOP', detail: `${navCount} navs, url=${url}` };
  if (navCount === 0) return { status: 'NO_RESPONSE', detail: '클릭 후 네비게이션/팝업 없음' };
  return { status: 'UNKNOWN', detail: `navs=${navCount}, url=${url}` };
}
