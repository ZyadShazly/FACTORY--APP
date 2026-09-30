# Accounting Verification Status

Source of truth for the staged final verification of the NextEP accounting implementation.

## Repository baseline

- Base branch inspected for Task 1: `main`
- Baseline commit: `48534c7bd0615176cc09a3dfa9de2c03c30abab0`
- Unrelated open PR at Task 1 start: #156 (`fix/accounting-verification-drilldown-20260930`) — intentionally excluded from Task 1.
- Verification rule: one task per run; later tasks remain NOT STARTED until explicitly requested.

## Task 1 — Database & Migrations

- **Status:** FIXED

### Checks performed

- Read current repository state, recent commits, open PRs, migration directory, and live Supabase migration history.
- Compared accounting migration history between repository and live database.
  - Final accounting migration count on this verification branch: **23**.
  - Final live accounting migration count: **23**.
  - Missing repository accounting versions in live: **0**.
  - Missing live accounting versions in repository: **0**.
  - Duplicate accounting migration versions: **0**.
- Checked full migration chain counts and ordering.
  - Baseline before this Task 1 fix: repository **181**, live **181**.
  - The repository validator enforces canonical 14-digit versions, unique versions, and baseline-first ordering.
  - Seven pre-existing non-accounting migrations have matching semantic names but different repository/live timestamps. This is documented in `docs/CURRENT_SYSTEM_STATUS.md`; accounting migrations are not affected.
- Static-scanned all accounting-related migrations for destructive behavior.
  - No `DROP TABLE`, `DROP COLUMN`, schema drop, or `TRUNCATE`.
  - No historical GL backfill query.
  - Controlled `DELETE` is limited to journal-line replacement inside protected journal editing logic.
  - Controlled trigger replacement in Production redefines `accounting_inventory_gl` to prevent double-posting.
- Inspected all live accounting tables, columns, constraints, foreign keys, indexes, RLS state, and policies.
  - Accounting tables: **9**.
  - All accounting tables have RLS enabled.
  - Accounting tables expose no direct SELECT/INSERT/UPDATE/DELETE grants to `anon` or `authenticated`.
  - Zero accounting-table RLS policies are intentional because the accounting data layer is RPC-only.
  - Invalid/unvalidated accounting constraints: **0**.
  - Critical GL/reporting foreign keys have supporting indexes.
  - Remaining unindexed accounting FKs are actor/audit or non-critical dimension references; no correctness issue identified.
- Inspected accounting RPCs and triggers.
  - Duplicate accounting trigger names on the same table: **0**.
  - Duplicate accounting function signatures: **0**.
  - Public accounting RPCs executable by `anon`: **0**.
- Verified Activation Date and historical-data protection.
  - Live accounting enabled: `true`.
  - Activation Date: `2026-09-30`.
  - `2026-09-29` source scope: **false**.
  - `2026-09-30` source scope: **true**.
  - `2026-10-01` source scope: **true**.
  - System journals before activation: **0**.
  - Source links before activation: **0**.
  - Current journal count at Task 1 close: **0**.
  - Current source-link count at Task 1 close: **0**.
- Existing-database upgrade path:
  - All accounting migrations through the Task 1 ACL fix are present in live migration history.
  - Live schema introspection confirms expected accounting tables/constraints/triggers/RPCs are present with no duplicates.
- Clean-install path:
  - Current full 182-migration chain was **not** replayed on a fresh disposable project during this task because there is no active Supabase development branch and the existing staging project is inactive.
  - Creating a new Supabase branch has a separate cost/confirmation requirement and was not done without user approval.
  - Existing repository evidence documents a prior fresh staging replay through 124 migrations in `docs/MIGRATION_BASELINE_RECONSTRUCTION_2026-08-11.md`.
  - Current static migration validation passes on the latest branch.

### Bugs found

1. Six internal `private.accounting_*` helper functions retained direct EXECUTE privilege for API roles. Because `authenticated` has USAGE on the `private` schema, this violated the intended internal-only ACL contract even though these helpers are not exposed as public Data API RPCs.

Affected helpers:

- `private.accounting_assert_entry_balanced(uuid)`
- `private.accounting_deferred_balance_guard()`
- `private.accounting_guard_account_hierarchy()`
- `private.accounting_guard_account_state()`
- `private.accounting_guard_period_overlap()`
- `private.accounting_guard_posting_account()`

### Fixes applied

- Added `20260930100959_accounting_private_helper_acl.sql`.
- Revoked EXECUTE from `PUBLIC`, `anon`, and `authenticated` for the six internal accounting helpers.
- Added regression coverage in `tests/accounting-private-helper-acl.test.mjs`.
- Applied the ACL migration to live Supabase.
- Rechecked live privileges: remaining anon/authenticated EXECUTE on those six helpers = **0**.

### Files changed

- `docs/accounting-verification-status.md`
- `supabase/migrations/20260930100959_accounting_private_helper_acl.sql`
- `tests/accounting-private-helper-acl.test.mjs`

### Tests run

- Repository ↔ live accounting migration parity audit.
- Full migration-version uniqueness/count audit.
- Accounting destructive-SQL static scan.
- Live schema/column/FK/constraint/index/RLS/ACL introspection.
- Duplicate trigger/function-signature audit.
- Activation boundary test.
- Historical journal/source-link audit.
- Supabase security and performance advisor review.
- Rollback-safe ACL smoke:
  - applied revokes inside a transaction;
  - executed protected journal create/post path;
  - verified balanced posting still succeeds;
  - verified authenticated direct helper EXECUTE is denied;
  - rolled back test data.
- GitHub Quality Gate #640: PASS.
- GitHub Quality Gate #642 after live-version filename alignment: PASS.
  - migration validation: PASS
  - repository tests: PASS
  - production build: PASS

### Remaining risks

- **Pre-existing, non-accounting migration-history drift:** seven older non-accounting migrations have semantic-name matches but different live/repository timestamps. This is documented and predates the accounting implementation. Do not reapply them solely because version IDs differ.
- **Fresh full-chain replay not repeated for all 182 migrations in this task:** a disposable active Supabase branch was not available without a separate cost/confirmation step.
- **Low-priority index opportunities:** several actor/audit foreign keys are not individually indexed. Critical GL, hierarchy, source-link, project, and reporting FKs are indexed.
- Supabase Advisor continues to report known project-wide notices such as RLS-enabled/no-policy tables, `btree_gist` in public, and intentional bearer-link Asset RPC warnings. The accounting tables' no-policy state is intentional and protected by revoked direct table grants.

## Task 2 — Chart of Accounts & Journal Entries

- **Status:** NOT STARTED

## Task 3 — Existing Module Accounting Integration

- **Status:** NOT STARTED

## Task 4 — Account Ledger & Trial Balance

- **Status:** NOT STARTED

## Task 5 — Balance Sheet

- **Status:** NOT STARTED

## Task 6 — Permissions & Security

- **Status:** NOT STARTED

## Task 7 — Full Existing System Regression

- **Status:** NOT STARTED

## Task 8 — Final Technical Validation

- **Status:** NOT STARTED

## Task 9 — Final Verification Report

- **Status:** NOT STARTED
