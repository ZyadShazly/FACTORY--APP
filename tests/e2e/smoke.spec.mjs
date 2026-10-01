import { test, expect } from "@playwright/test";

test.describe("Anonymous browser smoke", () => {
  test("login gate is visible and blocks empty submit", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "تسجيل الدخول" })).toBeVisible();
    await expect(page.getByText("الحسابات ينشئها مالك النظام أو مدير النظام فقط")).toBeVisible();

    await page.getByRole("button", { name: "دخول" }).click();
    await expect(page.getByText("اكتب رقم الهاتف أو البريد وكلمة السر")).toBeVisible();
  });

  test("invalid local phone format is rejected before authentication", async ({ page }) => {
    await page.goto("/");
    await page.getByPlaceholder("+9665XXXXXXXX").fill("055123");
    await page.locator('input[type="password"]').fill("not-a-real-password");
    await page.getByRole("button", { name: "دخول" }).click();
    await expect(page.getByText("اكتب رقم الهاتف بالصيغة الدولية، مثال: +9665XXXXXXXX")).toBeVisible();
  });
});
