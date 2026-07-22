# NextEP Pilot Acceptance — July 2026

## Goal
Validate the latest merged `main` as one complete product before pilot use.

## Required boundaries
- Authentication, profile bootstrap, roles, and navigation.
- Projects, budgets, milestones, members, files, and actual costs.
- Procurement, receiving, supplier invoices, inventory, warehouses, and production.
- Employees, work schedules, payroll, external labor, and project-cost posting.
- Assets, custody issue/return/settlement, WhatsApp confirmation, and alerts.
- Reporting, Excel workbooks, print/PDF, audit, settings, and realtime refresh.

## Safety rules
- No destructive schema change or production-data reset.
- Database smoke data must be created inside rollback-safe transactions.
- Existing approved, paid, posted, issued, received, and historical records are immutable except through explicit reversal workflows.
- Merge only after repository tests, build, clean-tree checks, Vercel, live integrity checks, and major-boundary regression all pass.

## Live database evidence
- Applied two permission-only migrations; neither migration changes application rows.
- Anonymous execution is blocked for every non-public `SECURITY DEFINER` routine.
- Trigger functions cannot be invoked by anonymous or authenticated API clients.
- The four token-protected asset confirmation endpoints remain available for WhatsApp custody links.
- Mutable `search_path` warnings were fixed for the four routines identified by the live Supabase advisor.
- Rollback-safe permission smoke test passed.
- Integrity regression returned zero orphan payroll records, asset assignments, inventory balances, and inventory movements.
- Integrity regression returned zero paid external-labor shifts without approval, negative inventory balances, invalid asset balances, unsafe archived warehouses, and test employee remnants.

## Residual operational advisories
- `btree_gist` remains in the `public` schema. Moving an installed extension is intentionally deferred because it is a separate operational change with dependency risk.
- Supabase leaked-password protection remains a project Auth setting to enable from the platform configuration; it is not changed by repository migrations.
- Tables using an RPC-only access model may show `RLS enabled, no policy` informational notices. Direct table access remains deny-by-default.

## Status
Database and permission regression passed. Final acceptance remains conditional on the latest repository tests, production build, clean-tree check, Vercel deployment, and PR mergeability succeeding on the final commit.
