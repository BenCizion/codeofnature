import { test, expect } from '@playwright/test';
import { loadCfg, findWidget } from '../lib/livere';

const cfg = loadCfg();

for (const site of cfg.sites) {
  test(`[widget] ${site.name} — 댓글창 렌더`, async ({ page }) => {
    test.skip(site.url.startsWith('PASTE'), 'sites.json 에 실제 URL 미설정');
    await page.goto(site.url, { waitUntil: 'domcontentloaded' });
    // 위젯은 비동기 주입 → 잠시 대기 후 메인+iframe 탐색
    await page.waitForTimeout(4000);
    const w = await findWidget(page, cfg);
    expect(w, `${site.name}: 댓글 위젯을 찾지 못함(셀렉터/URL 확인)`).not.toBeNull();
  });
}
