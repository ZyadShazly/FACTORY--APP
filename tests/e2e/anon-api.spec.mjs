import { test, expect } from "@playwright/test";

function requireApiEnv(testInfo) {
  const missing = ["UAT_SUPABASE_URL", "UAT_SUPABASE_ANON_KEY"].filter((name) => !String(process.env[name] || "").trim());
  testInfo.skip(missing.length > 0, `Missing UAT API settings: ${missing.join(", ")}`);
}

const headers = () => ({
  apikey: process.env.UAT_SUPABASE_ANON_KEY,
  "Content-Type": "application/json",
});

async function expectNoDataLeak(response) {
  if (!response.ok()) return;
  const body = await response.json();
  expect(Array.isArray(body)).toBeTruthy();
  expect(body).toHaveLength(0);
}

test.describe("Anonymous backend access", () => {
  test("anonymous caller cannot read profiles", async ({ request }, testInfo) => {
    requireApiEnv(testInfo);
    const response = await request.get(`${process.env.UAT_SUPABASE_URL}/rest/v1/profiles?select=id,role,status&limit=5`, { headers: headers() });
    await expectNoDataLeak(response);
  });

  test("anonymous caller cannot read audit log", async ({ request }, testInfo) => {
    requireApiEnv(testInfo);
    const response = await request.get(`${process.env.UAT_SUPABASE_URL}/rest/v1/audit_log?select=id,table_name,action&limit=5`, { headers: headers() });
    await expectNoDataLeak(response);
  });

  test("anonymous caller cannot invoke protected audit RPC", async ({ request }, testInfo) => {
    requireApiEnv(testInfo);
    const response = await request.post(`${process.env.UAT_SUPABASE_URL}/rest/v1/rpc/get_audit_log_visible`, {
      headers: headers(),
      data: {},
    });
    expect(response.ok()).toBeFalsy();
  });
});
