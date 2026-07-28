# Production Pilot Completion

Date: 2026-07-28

Branch: `agent/production-pilot-completion`

Base: Phase 3 Draft PR branch (`agent/inventory-pilot-hardening`)
Draft PR: [#88](https://github.com/ZyadShazly/FACTORY--APP/pull/88)

## Outcome

Phase 4 completes the pilot Production workflow without deleting operational history or writing production data directly from the UI:

- draft, plan, and release remain protected RPC actions;
- a material can be issued in multiple positive batches up to its remaining quantity;
- the order remains active after the first partial issue;
- operations support employee assignment, ready/start, pause with reason, resume, completion quantities, and quality review;
- manager/owner operation skip requires a reason and writes an audit record;
- order completion requires all material quantities, finalized operations, and approved quality for each completed operation;
- owner cancellation requires a reason, reverses every eligible legacy or partial material movement once, marks the order cancelled, and preserves audit/history;
- actual material cost is derived from non-reversed inventory issue movements and is returned only to Owner, Manager, and Accountant roles;
- active work is shown first with four KPI cards, compact progress summaries, and one visible primary action; completed/cancelled orders and detailed timelines stay collapsed or on demand.

## Bug traceability

### Bug C — partial material issue

- `issue_production_material` remains the only UI posting path.
- The UI displays required, issued, and remaining quantities and permits repeated issue batches while the order is `released` or `in_progress`.
- Both the current partial-issue ledger and the legacy single-movement reference are considered during cancellation.
- Over-issue remains rejected by the protected database workflow.

### Bug D — FK/dependency failure

- Production no longer exposes destructive deletion; cancellation and reversal are the operational exit.
- Assignment requires an active employee and uses `ON DELETE RESTRICT` foreign keys.
- Every new foreign key has a covering idempotent index.
- New database errors are mapped to friendly Arabic guidance.
- Global Safe Delete and Dependency Explorer work remains owned by its separate branch and was not duplicated here.

## Migration review

New migration:

`202607280001_production_pilot_completion.sql`

The migration is additive and was **not applied** by this mission. It:

- reconciles the Production execution/quality columns and immutable event ledger with `IF NOT EXISTS` guards;
- adds unique, idempotent covering indexes for `assigned_employee_id`, `assigned_by`, `operation_id`, and `actor_id`;
- fixes helper search paths, closes internal helper execution, and grants only intended authenticated RPCs;
- preserves existing Production orders, material issues, inventory movements, operation events, and audit records.

The live Supabase migration history already contains `20260721041533 production_execution_quality`, applied outside this mission. Draft PR #34 contains the older repository form of that migration and remains open. This phase does not reapply it and does not merge PR #34.

The historical employee workflow migration now guards its dependency query with an `information_schema.columns` check and dynamic SQL. This is a fresh-repository replay safeguard because that historical file may run before the new reconciliation migration; the new additive migration remains the recovery path for already-applied environments.

## Validation evidence

- Focused Production contracts: 19 passed, 0 failed.
- Full test script body (`node --test tests/*.test.mjs`): 329 total, 327 passed, 0 failed, 2 intentional skips.
- `npm test` launcher was unavailable in the bundled runtime because `npm` is not installed; the exact package script body was executed successfully with the bundled Node runtime.
- Production build: passed, 2,399 modules transformed.
- `git diff --check`: passed.
- Desktop/RTL visual QA: passed at 1,440×900 with no global overflow, four KPI cards, active-first cards, collapsed history, one primary action, and an on-demand execution drawer.
- Mobile/RTL visual QA: passed in a real 375×812 iframe viewport; the inner document measured `clientWidth=scrollWidth=360`, used a two-column KPI layout, and rendered its details dialog at the full 360px content width.
- Browser console: no warnings or errors.
- Remote Quality Gate: passed, run 314.
- Vercel deployment status: passed.

## Regression and safety

- No Supabase migration was applied.
- No live or local business data was created, rewritten, or deleted.
- No direct table mutation was added to Production UI.
- Procurement, Inventory, Project, payroll, assets, expenses, and other legacy modules were not changed.
- Existing partial issue, inventory ledger, protected RPC, role-boundary, and reporting contracts remain green in the full suite.
- Visual QA used an in-memory read-only fixture and a temporary 375×812 host page. Both were removed immediately after QA; no Supabase rows, users, `.env` files, or repository artifacts were created.
- No PR was merged and auto-merge was not enabled.
