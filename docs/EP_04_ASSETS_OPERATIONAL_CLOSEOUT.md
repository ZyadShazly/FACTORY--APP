# EP-04 — Assets Operational Closeout

## Decision

The Assets and custody workflow is operationally closed for the Pilot. EP-04
does not claim a maintenance-management product, vehicle fleet module,
depreciation engine, paid WhatsApp provider, or external OTP provider.

Those capabilities remain explicitly outside the Pilot boundary. The current
maintenance tab honestly exposes basic operational states only:
`needs_maintenance`, `under_maintenance`, and `damaged`.

## Repository closeout

| Control | Evidence |
| --- | --- |
| Custody issue, receiver confirmation, partial/full return, settlement, emergency reversal, immutable ledger, identity binding, and safe Realtime | Existing Assets foundation and hardening migrations plus their regression suites |
| Public confirmation-link security | `docs/acceptance/ASSET_PUBLIC_LINK_SECURITY_UAT.md` |
| Truthful authenticated-versus-bearer messaging and one renewal action | PR #111 |
| Complete Assets foreign-key coverage with bounded partial indexes | PR #112 |
| Active custody separated from collapsed immutable history | PR #113 |

## Live verification snapshot

Read-only verification after PR #112 and its production migration returned:

- 4 asset records;
- 5 custody assignments;
- 3 confirmed return events;
- 17 immutable ledger movements;
- 0 balance reconciliation mismatches;
- 34 new covering indexes installed;
- 0 remaining Supabase Advisor `unindexed_foreign_keys` notices for Assets
  tables.

No Asset, assignment, return, settlement, or movement row was inserted,
rewritten, deleted, reset, or fabricated during the closeout. The five existing
terminal custody assignments remain unchanged and are now visible in the
collapsed history surface added by PR #113.

## Accepted security boundaries

- `public.assets` remains RLS-protected without direct Data API policies; safe
  projection RPCs provide authorized reads.
- The four anonymous confirmation endpoints remain intentional bearer-link
  APIs with hashed expiring secrets, attempt locking, single use, masked data,
  and internal apply functions closed to API roles.
- Authenticated `SECURITY DEFINER` Assets APIs remain intentional only where the
  function performs its own active-profile, permission, identity, state, and
  row-lock checks.

These are accepted-with-controls boundaries, not unresolved defects. Future
changes must rerun the public-link UAT and Supabase Advisors.

## Acceptance result

- focused Assets regression: passed;
- full test suite at final implementation PR: 411 total, 409 passed, 2
  intentionally skipped;
- production build: passed;
- Quality Gate: passed for PRs #111, #112, and #113;
- Vercel preview and production deployments: passed;
- production database reconciliation: 0 mismatches.

EP-04 is complete. The next official package is **EP-05 — Commercial Lifecycle
Hardening**.
