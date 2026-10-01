import { test, expect } from "@playwright/test";

function requireEnv(testInfo, names) {
  const missing = names.filter((name) => !String(process.env[name] || "").trim());
  testInfo.skip(missing.length > 0, `Missing UAT secrets: ${missing.join(", ")}`);
}

async function loginAndReadSession(page, identifier, password) {
  await page.goto("/");
  await page.getByPlaceholder("+9665XXXXXXXX").fill(identifier);
  await page.locator('input[type="password"]').fill(password);
  await page.getByRole("button", { name: "دخول" }).click();
  await expect(page.getByRole("heading", { name: "تسجيل الدخول" })).toBeHidden({ timeout: 15_000 });

  return page.evaluate(() => {
    for (const [key, raw] of Object.entries(localStorage)) {
      if (!key.startsWith("sb-") || !key.endsWith("-auth-token")) continue;
      try {
        const parsed = JSON.parse(raw);
        if (parsed?.access_token) return { accessToken: parsed.access_token, userId: parsed.user?.id || null };
      } catch {}
    }
    return null;
  });
}

function apiHeaders(accessToken) {
  return {
    apikey: process.env.UAT_SUPABASE_ANON_KEY,
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
  };
}

test.describe("Runtime RBAC — direct backend checks", () => {
  test("Production can only read its own profile", async ({ page, request }, testInfo) => {
    requireEnv(testInfo, ["UAT_BASE_URL", "UAT_SUPABASE_URL", "UAT_SUPABASE_ANON_KEY", "UAT_PRODUCTION_PHONE", "UAT_PRODUCTION_PASSWORD"]);

    const session = await loginAndReadSession(page, process.env.UAT_PRODUCTION_PHONE, process.env.UAT_PRODUCTION_PASSWORD);
    expect(session?.accessToken).toBeTruthy();

    const response = await request.get(`${process.env.UAT_SUPABASE_URL}/rest/v1/profiles?select=id,role,status`, {
      headers: apiHeaders(session.accessToken),
    });
    expect(response.ok()).toBeTruthy();
    const rows = await response.json();
    expect(rows).toHaveLength(1);
    expect(rows[0].id).toBe(session.userId);
    expect(rows[0].role).toBe("production");
  });

  test("Production is denied from procurement workspace even when calling RPC directly", async ({ page, request }, testInfo) => {
    requireEnv(testInfo, ["UAT_BASE_URL", "UAT_SUPABASE_URL", "UAT_SUPABASE_ANON_KEY", "UAT_PRODUCTION_PHONE", "UAT_PRODUCTION_PASSWORD"]);

    const session = await loginAndReadSession(page, process.env.UAT_PRODUCTION_PHONE, process.env.UAT_PRODUCTION_PASSWORD);
    expect(session?.accessToken).toBeTruthy();

    const response = await request.post(`${process.env.UAT_SUPABASE_URL}/rest/v1/rpc/get_procurement_workspace_v2`, {
      headers: apiHeaders(session.accessToken),
      data: {},
    });
    expect(response.ok()).toBeFalsy();
    const body = await response.text();
    expect(body).toMatch(/procurement|access|required|permission/i);
  });

  test("Production is denied from audit log RPC", async ({ page, request }, testInfo) => {
    requireEnv(testInfo, ["UAT_BASE_URL", "UAT_SUPABASE_URL", "UAT_SUPABASE_ANON_KEY", "UAT_PRODUCTION_PHONE", "UAT_PRODUCTION_PASSWORD"]);

    const session = await loginAndReadSession(page, process.env.UAT_PRODUCTION_PHONE, process.env.UAT_PRODUCTION_PASSWORD);
    const response = await request.post(`${process.env.UAT_SUPABASE_URL}/rest/v1/rpc/get_audit_log_visible`, {
      headers: apiHeaders(session.accessToken),
      data: {},
    });
    expect(response.ok()).toBeFalsy();
  });

  test("Restricted Accountant is denied from audit log RPC", async ({ page, request }, testInfo) => {
    requireEnv(testInfo, ["UAT_BASE_URL", "UAT_SUPABASE_URL", "UAT_SUPABASE_ANON_KEY", "UAT_ACCOUNTANT_PHONE", "UAT_ACCOUNTANT_PASSWORD"]);

    const session = await loginAndReadSession(page, process.env.UAT_ACCOUNTANT_PHONE, process.env.UAT_ACCOUNTANT_PASSWORD);
    expect(session?.accessToken).toBeTruthy();

    const response = await request.post(`${process.env.UAT_SUPABASE_URL}/rest/v1/rpc/get_audit_log_visible`, {
      headers: apiHeaders(session.accessToken),
      data: {},
    });
    expect(response.ok()).toBeFalsy();
  });
});
