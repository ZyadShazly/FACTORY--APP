# Production & Manufacturing — Sprint Scope

## Goal

Add a protected production-workflow foundation on top of the existing `production_orders` table and the merged Inventory ledger, without deleting or rewriting historical production rows.

## In scope

- Preserve the current `production_orders` IDs, product/project links, quantities, dates, notes, and historical costs.
- Add an explicit production lifecycle: draft, planned, released, in_progress, completed, cancelled.
- Add operation steps and material requirements as append-only operational records.
- Reserve/release and issue materials through the protected Inventory contract; no direct stock mutation.
- Record actual material consumption and production completion without duplicate Actual Cost posting.
- Provide protected RPC-only mutations with fixed `search_path`, role checks, and audit events.
- Add rollback-safe smoke and major-boundary regression tests for Project → Production → Inventory → Actual Cost.

## Out of scope

- Full MRP planning, automatic BOM explosion, capacity scheduling, machine telemetry, subcontracting, quality-control laboratory workflows, and finished-goods valuation-method changes.
- Destructive conversion of legacy production orders.
- Direct DML access for `anon` or `authenticated` roles.

## Safety requirements

- Additive migrations only; legacy columns remain readable.
- Posted inventory movements remain immutable and reversible only through protected workflows.
- Production completion must be idempotent.
- Material consumption cannot exceed issued/reserved quantities or available stock.
- Cancellation after release requires an explicit reason and cannot silently delete consumption history.
- No duplicate project Actual Cost entry for the same production source line.

## Acceptance criteria

1. Existing production rows remain unchanged and queryable after migration.
2. A draft order can be planned and released only by an authorized role.
3. Released production can issue material through Inventory without negative stock.
4. Material consumption posts project Actual Cost exactly once through the canonical source contract.
5. Completion is idempotent and preserves all ledger history.
6. Cancellation/reversal restores inventory and reverses linked Actual Cost when applicable.
7. RLS and direct grants are reviewed live after migration.
8. Rollback-safe smoke tests leave no test rows.
9. Full repository tests/build and both Vercel checks pass before merge.
10. Major regression covers Project → Production → Inventory → Actual Cost → Reversal.