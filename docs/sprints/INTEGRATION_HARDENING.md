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

## Preflight findings
The current UI still mixes direct production-table access with the protected production RPC contract, and inventory/report calculations still depend on legacy operational rows instead of the protected ledger. Reporting work remains blocked until these sources are unified.

## Exit criteria
- no unauthorized direct production mutation path remains in the UI
- Production role can perform only the intended workflow actions
- inventory balances reconcile to the ledger for existing records
- legacy purchase actions are redirected or explicitly blocked
- all automated and manual gates pass
