# Integration & Hardening Sprint

## Goal
Make the protected production workflow and inventory ledger the canonical application contracts before Reporting & Analytics begins.

## Scope
- replace direct `production_orders` UI mutations with protected RPC workflow actions
- align Production-role actions with the permissions defined by the production migrations
- use inventory-ledger balances as the canonical inventory and reporting source
- remove or redirect legacy direct-purchase paths that bypass the protected workflow
- preserve all existing operational and historical data

## Safety constraints
- additive or compatibility-preserving schema changes only
- no destructive rewrites, truncation, or historical backfills without explicit evidence and review
- migration SQL must be reviewed before live application
- live schema, grants, RLS, and RPC execution permissions must be reviewed after application
- smoke tests must be read-only or transactionally rolled back
- merge requires repository tests/build, Vercel checks, and full-program regression at production/inventory/procurement/reporting boundaries

## Preflight result
The latest merged `main` already contains the intended runtime hardening:

- `ProductionWorkspace` uses `get_production_workspace` and protected action RPCs for create, plan, release, material issue, operation transitions, completion, and cancellation.
- `InventoryWorkspace` uses `get_inventory_workspace`, whose balances are sourced from the inventory ledger.
- the active materials and procurement workspaces do not expose the legacy direct-purchase mutation path.
- `tests/critical-hardening-contract.test.mjs` prevents regressions back to direct production mutations or legacy stock calculations.

Because the required protected contracts were already present and matched the live database, this sprint requires no new migration. Applying an empty, duplicate, or speculative migration would add risk without changing the schema.

## Live verification — FACTORY APP

- project status: `ACTIVE_HEALTHY`
- protected production and inventory RPCs exist with the expected signatures
- `anon` has no execute privilege on the reviewed RPCs
- `authenticated` has execute privilege; each function performs its own identity and role checks
- reviewed operational tables have RLS enabled
- direct `anon`/`authenticated` table grants were absent for the RPC-only operational tables
- inventory ledger reconciliation query returned zero mismatches; the live project currently had zero balance rows to reconcile
- unauthenticated production and inventory workspace calls were rejected inside a transaction that was rolled back

## Regression boundaries

The repository contract suite covers these module boundaries:

- production UI → protected production RPCs
- production material issue → inventory movement ledger
- inventory UI → canonical ledger workspace
- materials catalog → purchase-request workflow
- procurement UI → protected procurement workspace
- reporting readiness → canonical production and inventory sources

## Exit criteria
- [x] no unauthorized direct production mutation path remains in the UI
- [x] Production role is constrained by protected RPC authorization
- [x] inventory balances reconcile to the ledger for existing records
- [x] legacy purchase actions are redirected or blocked
- [x] rollback-safe live smoke tests passed
- [ ] repository tests/build and GitHub quality gate pass on the final commit
- [ ] Vercel final preview is Ready
