import { defineConfig, devices } from '@playwright/test';

// 환경 매트릭스 — 사용자 환경 목록에 매핑:
//  PC(Windows/Mac)  → pc-chrome / pc-firefox / pc-safari(WebKit)
//  모바일 iOS       → mobile-ios-safari (WebKit)
//  모바일 Android   → mobile-android-chrome (Chromium)
// ※ 엔진은 OS 비의존 빌드라 "진짜 Windows vs Mac / 실기기 iOS·Android"는
//   이 스위트를 그 OS에서 돌리거나 BrowserStack 연동으로 확장(README 참조).
export default defineConfig({
  testDir: './tests',
  timeout: 90_000,
  expect: { timeout: 15_000 },
  retries: 1,
  workers: 3,
  reporter: [
    ['list'],
    ['json', { outputFile: 'results/results.json' }],
    ['html', { open: 'never', outputFolder: 'results/html' }],
  ],
  use: {
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    { name: 'pc-chrome',  use: { ...devices['Desktop Chrome'] } },
    { name: 'pc-firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'pc-safari',  use: { ...devices['Desktop Safari'] } },
    { name: 'mobile-ios-safari',     use: { ...devices['iPhone 14'] } },
    { name: 'mobile-android-chrome', use: { ...devices['Pixel 7'] } },
  ],
});
