# Continue Implementation Log — 2026-08-10

Phase: `CONTINUE IMPLEMENTATION` (not a Final Release Audit)

Starting point: PR #119, branch `uat/fix-all-20260803`, implementation commit `049e385`.
Working branch: `product/continue-implementation-20260810`.

## Completed batches

### Commercial advances — `955e93a`

- Added customer/supplier advance workspaces to the operational ledgers.
- Added document-level allocation caps, source/due locking, idempotency and reversal history.
- Prevented cancellation/deletion while active allocations exist.
- Added retry-safe command IDs for receipt/payment posting.

### Managed phone accounts — `a40aa5e`

- Removed public self-registration from the production UI and latest database contract.
- Added phone-or-email password login without SMS dependency.
- Added Owner/Manager account creation through an authenticated Edge Function; no service credential is exposed to the browser.
- Enforced hierarchy: Owner may create managed roles; Manager is limited to Accountant/Production.
- Added unique normalized phone identity, temporary-password first-login gate and protected phone changes.
- Removed destructive account deletion from the daily Team workflow; suspension remains the history-preserving action.

### Project document history — `87b1923`

- Replaced destructive project-file deletion with reasoned archive/restore RPCs.
- Retained private storage objects and added project activity plus audit records.
- Blocked direct metadata deletion and direct archive-state mutation.

### Global operational search — `21f9355`

- Project results and overdue-project notifications now open the referenced project workspace.
- Added explicit empty/error states.
- Prevented late search responses from replacing newer query results.

### Project base-currency integrity — current batch

- Removed hard-coded SAR/EGP labels from project budgets, operational finance screens and Excel numeric styles.
- Bootstrapped the configured system currency after authentication and propagated Owner setting changes immediately.
- Made new project budgets and Actual Cost entries use the configured base currency and reject mixed-currency writes.
- Protected the base-currency code from casual changes after monetary history exists; symbol, locale and decimals remain configurable.
- Added an Owner-only, read-only reconciliation RPC for historical project budget, template and Actual Cost currency mismatches.
- Preserved every historical row; no currency value or financial amount was rewritten.

## Verification snapshot

- Full regression after the base-currency batch: 471 passed, 0 failed, 2 optional integrations skipped (473 total).
- Production build passed after every batch.
- `git diff --check` passed.
- New migrations were added to the repository only; none were applied to Production.
- No Production data was read or modified.

## Deferred mandatory Final Release Gates

These remain required and are not marked complete:

- Apply and validate the pending migration chain in local/disposable/staging Supabase.
- Deploy and exercise `admin-manage-user` in a non-production environment.
- Execute the Owner / Manager / Accountant / Production allow-and-deny Role Matrix.
- Run the separate full Final Release Audit and issue GO/NO GO only at that stage.
