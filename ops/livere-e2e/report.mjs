// Playwright JSON 결과 → 환경×테스트 매트릭스 요약 → Slack(있으면) 전송.
import { readFileSync } from 'fs';

const WH = process.env.SLACK_WEBHOOK_URL || '';
let data;
try { data = JSON.parse(readFileSync('results/results.json', 'utf8')); }
catch (e) { console.error('결과 파일 없음(results/results.json):', e.message); process.exit(0); }

const rows = {};            // { testTitle: { project: '✅|❌|➖' } }
const projects = new Set();
const fails = [];

function walk(suite) {
  (suite.suites || []).forEach(walk);
  (suite.specs || []).forEach((spec) => {
    (spec.tests || []).forEach((t) => {
      const proj = t.projectName || '?';
      projects.add(proj);
      const last = (t.results || []).slice(-1)[0] || {};
      const st = last.status || t.status || 'unknown';
      const mark = st === 'passed' ? '✅' : st === 'skipped' ? '➖' : '❌';
      (rows[spec.title] ||= {})[proj] = mark;
      if (mark === '❌') {
        const msg = ((last.error && last.error.message) || st).split('\n')[0].slice(0, 180);
        fails.push(`${spec.title} @ ${proj}: ${msg}`);
      }
    });
  });
}
(data.suites || []).forEach(walk);

const projs = [...projects];
let grid = 'test \\ env'.padEnd(34) + projs.join('  ') + '\n';
for (const [name, by] of Object.entries(rows)) {
  grid += name.slice(0, 32).padEnd(34) + projs.map((p) => (by[p] || '·').padEnd(p.length)).join('  ') + '\n';
}

const nFail = fails.length;
const header = nFail
  ? `:rotating_light: 라이브리 E2E 실패 ${nFail}건 (환경×테스트)`
  : `:white_check_mark: 라이브리 E2E 전부 통과`;
const text = `${header}\n\`\`\`\n${grid}\`\`\`` + (nFail ? `\n*실패 상세*\n` + fails.map((f) => `• ${f}`).join('\n') : '');

console.log(text);
if (WH) {
  try {
    const r = await fetch(WH, { method: 'POST', headers: { 'Content-type': 'application/json' }, body: JSON.stringify({ text }) });
    console.error('slack:', r.status);
  } catch (e) { console.error('slack 전송 실패:', e.message); }
}
process.exit(nFail ? 1 : 0);
