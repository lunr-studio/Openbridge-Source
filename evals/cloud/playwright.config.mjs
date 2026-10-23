import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests', testMatch: '**/*.spec.mjs', fullyParallel: true,
  forbidOnly: true, retries: 0, workers: 2, timeout: 15_000,
  expect: { timeout: 5_000 },
  use: { actionTimeout: 5_000, trace: 'off' },
  reporter: process.env.OPENBRIDGE_EVAL_RAW_REPORT
    ? [['json', { outputFile: process.env.OPENBRIDGE_EVAL_RAW_REPORT }]] : [['list']],
  projects: [{ name: 'D' }],
});
