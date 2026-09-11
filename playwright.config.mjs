import { defineConfig, devices } from "@playwright/test";

const externalBaseUrl = String(process.env.UAT_BASE_URL || "").trim();
const localBaseUrl = "http://127.0.0.1:4173";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  timeout: 30_000,
  expect: { timeout: 7_500 },
  reporter: [
    ["list"],
    ["html", { outputFolder: "playwright-report", open: "never" }],
  ],
  use: {
    baseURL: externalBaseUrl || localBaseUrl,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
  ],
  webServer: externalBaseUrl
    ? undefined
    : {
        command: "npm run build && npm run preview -- --host 127.0.0.1 --port 4173",
        url: localBaseUrl,
        reuseExistingServer: !process.env.CI,
        timeout: 120_000,
        env: {
          ...process.env,
          VITE_SUPABASE_URL: process.env.VITE_SUPABASE_URL || "http://127.0.0.1:54321",
          VITE_SUPABASE_ANON_KEY: process.env.VITE_SUPABASE_ANON_KEY || "local-test-anon-key",
        },
      },
});
