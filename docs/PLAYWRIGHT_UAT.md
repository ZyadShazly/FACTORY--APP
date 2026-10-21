# Playwright UAT

This suite separates safe smoke checks from authenticated runtime authorization checks.

## What runs automatically on pull requests

- Browser renders the login gate.
- Empty login is rejected locally.
- Invalid phone format is rejected before authentication.
- Authenticated/API tests are skipped when UAT secrets are absent.

No Production write is performed by the current suite.

## Manual runtime UAT

Run the `playwright-uat` workflow from GitHub Actions and choose the deployment URL.

Configure these GitHub Actions secrets before running authenticated checks:

- `UAT_SUPABASE_URL`
- `UAT_SUPABASE_ANON_KEY`
- `UAT_PRODUCTION_PHONE`
- `UAT_PRODUCTION_PASSWORD`
- `UAT_ACCOUNTANT_PHONE`
- `UAT_ACCOUNTANT_PASSWORD`

Use dedicated UAT accounts only. The Accountant account used here should be a restricted Accountant without Audit Log access.

## Runtime security checks currently covered

- Anonymous caller cannot read profiles.
- Anonymous caller cannot read Audit Log.
- Anonymous caller cannot invoke protected Audit RPC.
- Production can read only its own profile.
- Production cannot call Procurement workspace directly.
- Production cannot call Audit Log RPC directly.
- Restricted Accountant cannot call Audit Log RPC directly.

These tests intentionally call Supabase directly after browser authentication, so they validate backend authorization rather than UI hiding alone.

## Local run

Install the runner without changing the project lockfile:

```bash
npm install --no-save --package-lock=false @playwright/test@1.55.0
npx playwright install chromium
npx playwright test --config=playwright.config.mjs
```

For authenticated runtime tests, export the same `UAT_*` environment variables listed above. Without them, those tests are skipped.

## Safety rule

Do not add destructive Production scenarios to this suite by default. Any future test that creates, updates, reverses, pays, receives, issues inventory, or changes identity state must use dedicated UAT data and an explicit opt-in environment flag.
