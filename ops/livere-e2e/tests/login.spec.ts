import { test, expect } from '@playwright/test';
import { loadCfg, classifyLogin } from '../lib/livere';

const cfg = loadCfg();

for (const site of cfg.sites) {
  test(`[login] ${site.name} — 로그인 진입`, async ({ page, context }) => {
    test.skip(site.url.startsWith('PASTE'), 'sites.json 에 실제 URL 미설정');
    await page.goto(site.url, { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(4000);

    const r = await classifyLogin(page, context, cfg);
    const env = test.info().project.name;
    console.log(`[${env}] ${site.name} login => ${r.status} :: ${r.detail}`);
    test.info().annotations.push({ type: 'login-result', description: `${r.status} (${r.detail})` });

    // 정상 = 로그인 IdP 진입(OK). NO_RESPONSE/REDIRECT_LOOP 가 이번 장애 신호.
    expect(r.status, `로그인 플로우 비정상: ${r.status} — ${r.detail}`).toBe('OK');
  });
}
