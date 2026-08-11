# Migration Baseline Reconstruction — 2026-08-11

Scope: migration infrastructure repair only. This is not a Final Release Audit
and does not authorize a Production migration-history repair.

## Root cause

- The repository originally used `schema.sql` as a one-time SQL Editor script.
  Its objects were deployed before `supabase/migrations` became the source of
  truth, so the first migration attempted to alter `public.profiles` without
  creating it.
- The early application also depended on `rentals`, `expenses`,
  `products.item_type`, and `production_orders.waste_percentage`. These objects
  existed in the historical application/live contract but had no creating
  repository migration.
- Migration files used mixed-length versions, letter suffixes, and duplicate
  versions. Supabase CLI therefore skipped letter-suffixed files and could not
  provide a stable total order.
- Production records many already-applied migrations under the timestamps
  generated when they were applied, rather than the former repository versions.
  Production history was inspected read-only and was not repaired or mutated.

## Canonical baseline and ordering

`20260711165136_legacy_erp_baseline.sql` now creates the twelve real legacy
operational tables, their original foreign keys and checks, the manager helper,
RLS, explicit Data API grants, and Realtime publication membership. It contains
no application data or fabricated compatibility tables.

Every migration filename now matches:

```text
<14-digit timestamp>_<snake_case>.sql
```

Where Production has a matching migration name, the repository uses the latest
matching applied Production timestamp. Earlier or repository-only migrations
retain their logical timestamp with explicit seconds. This removes duplicate
versions, the `004a`–`004f` filenames, and ambiguous lexical ordering.

The final infrastructure closeout migration revokes API execution from three
internal trigger helpers found during the fresh replay and removes the obsolete
`profiles_update_own` policy, which is absent from the current Production schema.
Trigger behavior is unchanged.

## Validation evidence

- Staging project: `qxucepnpluwygltfcnsz` (non-production).
- Initial state: no public tables and no migration history.
- Result: all 124 repository migrations applied sequentially, from baseline to
  `20260811080000_migration_chain_security_closeout.sql`.
- Resulting public schema: 82 tables, all with RLS enabled; 102 policies, 164
  application triggers, and 366 indexes before the final ACL-only closeout.
- No SECURITY DEFINER routine lacks a fixed `search_path`.
- The three internal trigger helpers are not executable by `anon` or
  `authenticated` after closeout.
- Static validator: canonical filenames, unique versions, baseline-first order,
  required tables/security contract, and no baseline application-data inserts.
- Automated tests: 531 passed, 0 failed, 2 optional integrations skipped (533
  total).

## Deliberately unresolved release work

- Production migration history still requires a separately reviewed alignment
  plan. No `migration repair`, history edit, or Production DDL was performed.
- Final Release Validation must reassess the existing Advisor findings,
  including three security-definer reconciliation views, the four intentional
  token-based anonymous Assets RPCs, unvalidated legacy-compatible constraints,
  RLS-enabled/internal tables with no direct policies, and performance notices.
- The final allow/deny Role Matrix and Production release order remain separate
  mandatory gates.
