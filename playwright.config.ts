import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  testDir: './test/browser',
  fullyParallel: true,
  workers: 2,
  timeout: 30000,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',
  use: { baseURL: 'http://127.0.0.1:8092/subwaysForNerds/', trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'], viewport: { width: 1440, height: 1000 } } },
    { name: 'mobile', use: { ...devices['Pixel 7'], viewport: { width: 390, height: 844 } } },
    ...(process.env.RUN_WEBKIT ? [{ name: 'webkit-mobile', use: { ...devices['iPhone 13'] } }] : []),
  ],
  webServer: { command: 'npx tsx test/fixture-server.ts', url: 'http://127.0.0.1:8092/healthz', reuseExistingServer: !process.env.CI },
});
