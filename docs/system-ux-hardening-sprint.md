# System UX hardening sprint

This sprint removes known user-facing defects across the application while preserving historical data and existing operational records.

## Priority 1 — Custody and confirmation safety

- Allow exceptional return workflows to proceed without a bearer-link token.
- Distinguish missing, invalid, expired, replaced, cancelled, already-confirmed, and temporarily locked links.
- Track confirmation-link lifecycle explicitly: created, sent, opened, confirmed, expired, replaced, and cancelled.
- Add safe send, resend, and copy-link actions with audit metadata.
- Ensure tokens are not invalidated before the underlying issue or return workflow completes.
- Replace database error text with user-facing domain messages.
- Regression-test issue, recipient confirmation, return, authenticated confirmation, exceptional return, cancellation, expiry, resend, and reversal boundaries.

## Priority 2 — Employee history safety

- Keep foreign-key history intact.
- Replace destructive employee deletion with inactivation or archival when linked records exist.
- Exclude inactive employees from new operational selections while keeping them visible historically.
- Present clear messages when deletion is blocked.

## Priority 3 — Projects usability

- Simplify the project list with useful status summaries, overdue indicators, sorting, and card/table views.
- Reorganize the workspace into five user-oriented groups: Summary, Execution, Resources, Financials, and Documents & Activity.
- Hide or disable unfinished sections.
- Reduce overview density and move advanced lifecycle/progress controls behind focused actions.
- Clarify lifecycle, execution stage, and progress as separate concepts.
- Add due-date, blocker, manager, and budget-variance signals.
- Improve project creation and editing flow without changing existing records.

## Priority 4 — Cross-system consistency

- Centralize friendly error mapping.
- Centralize operation success/failure feedback.
- Centralize currency formatting.
- Add global currency settings while preserving historical transaction currency semantics.
- Verify active navigation state across desktop and mobile layouts.

## Merge gates

- Review every migration before applying it.
- Apply only to the FACTORY APP Supabase project.
- Verify live schema, constraints, RLS, grants, and RPC permissions afterward.
- Run rollback-safe smoke tests and major-boundary regression tests.
- Run full repository tests and production build.
- Require successful Vercel checks.
- Merge only when every gate passes.
