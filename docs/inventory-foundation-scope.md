# Inventory Foundation — Sprint Scope

## Goal

Build the next additive operational boundary after Procurement: a protected inventory ledger that can receive approved procurement receipts and later issue materials to projects and production without double-counting cost.

## In scope

- Warehouses and storage locations.
- Inventory items and units of measure.
- Immutable stock movement ledger.
- Cached on-hand balances updated transactionally from the ledger.
- Procurement receipt posting contract from confirmed goods receipt items.
- Project material issue contract with canonical source references.
- Reversal workflow; no destructive deletion of posted movements.
- RPC-only writes, least-privilege permissions, audit coverage, and Realtime-safe refresh signals.
- Rollback-safe regression tests and live verification queries.

## Accounting boundary

- A procurement receipt increases inventory quantity and value but does not create a second project Actual Cost entry.
- A project material issue decreases inventory and posts Actual Cost exactly once through the existing protected Actual Cost source contract.
- Reversals preserve history and must reverse both quantity and any linked Actual Cost posting through canonical references.
- Custody and supplier invoice accounting remain governed by their existing contracts.

## Out of scope

- Full MRP, BOM explosion, production orders, lot/serial tracking, landed-cost allocation, cycle counting, and valuation-method changes.
- Destructive conversion of legacy product or purchase data.
- Direct table access for anon or authenticated roles.

## Security requirements

- RLS enabled on all exposed-schema tables.
- Direct DML revoked from anon and authenticated.
- SECURITY DEFINER used only when necessary, with fixed search_path, explicit authorization, and narrow EXECUTE grants.
- Cross-project and cross-warehouse references validated in PostgreSQL.
- Posted ledger rows immutable except through protected reversal functions.

## Acceptance criteria

1. Confirmed procurement receipt can post one inventory receipt movement and cannot post twice.
2. Project issue cannot exceed available stock.
3. Project issue posts Actual Cost once using the existing source contract.
4. Reversal restores stock and reverses linked Actual Cost exactly once.
5. Unauthorized direct table access is blocked.
6. Rollback-safe smoke scenario leaves no test data.
7. Full repository tests/build and Vercel checks pass before merge.
8. Major-boundary regression covers Procurement -> Inventory -> Actual Cost.
