# Reporting & Analytics Sprint

## Goal
Build a protected, consistent reporting foundation from the latest merged `main` without duplicating operational data or weakening module permissions.

## Initial scope
- centralize KPI definitions across Projects, Procurement, Inventory, Production, Actual Cost, Payroll, and Custody
- use protected read models or RPCs instead of direct access to restricted operational tables
- standardize date, currency, empty, loading, and permission states
- validate reports against existing operational records with rollback-safe checks

## Safety constraints
- additive or compatibility-preserving migrations only
- no destructive denormalization, truncation, or historical rewrites
- no report may bypass source-module authorization
- migration SQL must be reviewed before live application
- live schema, grants, RLS, and RPC permissions must be reviewed after application
- smoke tests must be read-only or transactionally rolled back
- merge requires repository tests/build, Vercel checks, and regression across all major module boundaries

## Preflight
Inspect existing report pages, dashboard queries, views, RPCs, and source-of-truth contracts before designing any migration.

## Exit criteria
- [ ] KPI definitions are documented and consistent across modules
- [ ] protected reporting read paths are implemented
- [ ] migration reviewed before application
- [ ] live schema and permissions reviewed after application
- [ ] rollback-safe smoke tests pass
- [ ] repository tests and build pass
- [ ] Vercel preview is Ready
- [ ] full-program regression passes
