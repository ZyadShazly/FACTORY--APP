# NextEP — SU-only comprehensive editing (all modules)

## Scope
Owner account `su@nextep.local` requests the ability to modify, correct, archive, and where possible safely delete records throughout NextEP, not only assets. Any mutation must show a BEFORE-SAVE impact assessment and its permission must be verified within the database, keyed to the authenticated user UUID for each deployment.

## Modules
- Projects, budgets, milestones, files
- Purchases, supplier settlements, expenses, advances, petty cash and custody
- Inventory, materials, finished goods, stock movements, production
- Sales, customers, receipts, returns
- Accounting COA, draft/posted journals, VAT, financial periods and reports
- Employees, payroll, daily labor and calendars
- Assets, tools, assignments and maintenance
- Settings, profiles, role management, audit history

## Required operation design
1. **Read-only impact preview** before any destructive or financially consequential change:
   source object + current values, proposed values, linked documents, affected balances, AP/AR, GL, inventory, custody, tax, budget, people and reports.
2. **Authorized action** only through a server-side database RPC; do not rely on visible buttons, email supplied by client or UI role; verify auth.uid() against a centrally configured allowlisted user ID and active owner profile. A separate UUID is required in each Supabase project.
3. **Severity levels**:
   - Low: reversible metadata update, retain old/new audit history.
   - Medium: state or quantity correction with balancing movements, reason required.
   - High: posted accounting/custody/stock edits; create reversal-and-replacement operations, do not rewrite immutable historical source.
   - Blocked: impossible to preserve referential integrity; offer archive, reversal, correction or new document.
4. **Preflight/postflight checks**: balance invariants, transactions, current DB version, stale edits, concurrent mutations and idempotency.
5. **Rollback** via recorded compensation, not erasing audit entries.
6. **No mutation of live FACTORY-APP-STAGING** until test on disposable environment and backup.
7. **Negative tests**: other owner, manager, accountant and unauthenticated requests are denied at DB boundary; authenticated SU can perform only supported actions.
8. **Test both deployments separately** and confirm identity UUID/project configuration before release.

## Reality check
Existing `owner` receives every known application action permission (src/app/actionPermissions.js), but this does not mean every data-model constraint can or should be bypassed. Comprehensive modification requires module-specific correction workflows and previews. A universal raw SQL or unlimited delete button would silently corrupt ledgers, stock, payroll, or custody.

## Current PR scope
PR #177 contains **assets only** and is NOT a complete SU control suite. Do not merge it as a purported system-wide implementation.
