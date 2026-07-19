# Project Estimated Budget

## Scope

This sprint activates the Estimated Budget tab inside the existing Project
Workspace. It does not rebuild Projects and does not implement Actual Cost,
Quotations, Purchasing, Inventory consumption, Factory Labor allocation, Petty
Cash, GL, AR, AP, MRP, Production costing, or Employee Cash Custody.

Migration order:

1. `202607190001_project_workspace_upgrade.sql`
2. `202607190002_project_workspace_performance_hardening.sql`
3. `202607190003_project_estimated_budget.sql`

Migration `003` fails fast when the merged PR #13 Project Workspace tables or
authorization functions are missing. It preserves all project IDs, files,
activities, milestones, members, lifecycle states, progress, and cost history.

## Data model and versioning

- `project_budget_versions` contains the version header, totals, workflow,
  approval identities, rejection reason, and timestamps.
- `project_budget_sections` groups items and stores a cached subtotal.
- `project_budget_items` stores quantity, unit cost, waste, category, optional
  supplier/department/milestone, and future source references.
- `project_budget_templates`, `project_budget_template_sections`, and
  `project_budget_template_items` provide editable reusable templates.

Version numbers are allocated while the project row is locked. There may be
multiple historical versions but only one `approved` version per project,
enforced by a partial unique index. Approving a newer submitted version and
superseding the previous approved version happen in the same transaction.

Approved, rejected, superseded, and cancelled history is immutable. A submitted
version can only be approved or rejected. An approved version is edited only by
copying it to a new draft. An empty draft is deleted on cancellation; a populated
draft becomes `cancelled` so its history remains visible.

Workflow:

`draft → submitted → approved`

`submitted → rejected`

`approved → superseded` only through approval of a newer version.

`draft → cancelled`

## Categories and calculations

The category vocabulary separates Materials, Production/Subcontracting,
Logistics, Labor, Assets/Equipment, and Other. Factory salaried labor and daily
labor are separate categories. Asset custody and Employee Cash Custody are not
cost categories. Only approved asset usage, rental, fuel, operation,
depreciation, or maintenance allocation may be estimated.

All persisted calculations use PostgreSQL `numeric`, with currency results
rounded to two decimals:

```text
base_cost = round(quantity × unit_cost, 2)
waste_amount = round(base_cost × waste_percentage / 100, 2)
total_with_waste = round(base_cost + waste_amount, 2)
section_subtotal = sum(total_with_waste)
budget_subtotal = sum(section_subtotal)
expected_total_cost = subtotal + contingency + overhead
target_sale_price = expected_total_cost + target_profit
```

Contingency, overhead, and target profit each have an explicit mode:
`none | fixed | percentage`. The inactive representation is reset to zero so a
fixed and a percentage value cannot be charged accidentally at the same time.
Negative values, non-finite client values, and percentages outside their check
constraints are rejected. Default currency is SAR and the ISO-style three-letter
currency code remains configurable.

## Approval and activation

Submission requires at least one positive item and calculates the final totals
before freezing the submitted snapshot. Approval locks the project and budget,
validates those immutable positive totals, supersedes the old approved version,
and updates the Project Workspace expected cost and target sale price atomically.

For a new project, `ready_for_activation → active` requires:

- a customer;
- a project manager;
- a valid planned start/delivery range;
- a current approved budget;
- at least one positive approved item;
- `expected_total_cost > 0`;
- no blocking readiness check.

Projects migrated by PR #13 retain the stored `legacy_activation_exempt=true`
flag. Existing active/completed/closed/cancelled projects are never evaluated
retroactively. This exemption is stored and auditable, not inferred from dates.

An Owner may store one exceptional activation override with a mandatory reason,
actor, and timestamp. The override does not silently activate a project: it only
satisfies the budget readiness check, and the normal lifecycle RPC is still
required. Manager has no default approval or activation-override permission.

## Permissions

| Permission | Owner | Manager default | Accountant default | Production |
| --- | --- | --- | --- | --- |
| view/create/edit/submit | Yes | Yes | Yes | View only when explicitly granted |
| approve | Yes | Only when explicitly granted | Only when explicitly granted | No |
| reject | Yes | Only when explicitly granted | Yes | No |
| view financials | Yes | Yes | Yes | Only when explicitly granted |
| manage templates | Yes | Yes | No by default | No |
| activation override | Yes | No | No | No |

Project membership is required for scoped non-administrative access but never
grants a budget permission by itself. Quantities/descriptions and financial
values are separately projected. Unit cost, totals, waste amount, contingency,
overhead, profit, and target sale price are removed unless
`project_budget_view_financials` is present.

## RLS, RPCs, and audit

All seven new tables have RLS enabled and no direct `anon` or `authenticated`
table grants. The frontend reads through `get_project_budget_visible` and
`compare_project_budget_versions`. Every write uses a protected RPC with active
identity, project visibility, granular permission, status validation, fixed
`search_path`, row locks, and intentional grants.

Business RPCs:

- `create_project_budget_draft`
- `copy_project_budget_version`
- `update_project_budget_header`
- `save_project_budget_section`
- `reorder_project_budget_sections`
- `save_project_budget_item`
- `reorder_project_budget_items`
- `delete_project_budget_draft_item`
- `submit_project_budget`
- `approve_project_budget`
- `reject_project_budget`
- `cancel_project_budget_draft`
- `create_budget_template_from_version`
- `create_budget_from_template`
- `get_project_budget_visible`
- `compare_project_budget_versions`
- `get_project_activation_readiness`
- `override_project_activation_budget_requirement`

Internal helpers and trigger functions have EXECUTE revoked from `PUBLIC`,
`anon`, and `authenticated`. Row changes use the immutable Audit Log trigger;
workflow actions also write human-readable Project Activity events.

## Realtime

Budget tables are deliberately not published as financial payloads. Their
statement triggers update the existing safe `project_realtime_signal` singleton.
The central client channel refreshes the safe Projects projection, and the open
Budget tab reloads its safe RPC projection. No second Supabase channel is created.
The existing reconnect, cleanup, retry, and reconciliation behavior remains the
single source of Realtime lifecycle management.

## Future Employee Cash Custody contract

Cash issued to an employee is a receivable/custody balance, not an immediate
project expense. This sprint creates no custody ledger or screens. It defines
the future integration contract only:

- `employee_cash_custody_settlement_line` is the only custody source type that
  may post to Actual Cost.
- The required source state is `approved`; an advance, unapproved invoice,
  returned cash, open balance, overdue status, or write-off request cannot post.
- Future custody may link to project, milestone, cost center, purchase request,
  and Estimated Budget item.
- Future custody workflow must support advance amount, approved invoices,
  returned cash, excess employee claim, partial/full settlement, overdue
  custody, and privileged write-off approval.
- Every Actual Cost row has a canonical `source_reference_key` plus
  `source_type + source_id + source_line_reference + allocation_revision`.
- The canonical key must be shared by equivalent Expenses, Purchases, Petty Cash,
  Supplier Invoice, and Custody Settlement events so the unique constraints
  prevent double counting.
- Settlement revisions are append-only source history. Approved source records,
  returns, excess claims, and write-offs require immutable audit events in the
  future module.

`project_cost_source_contracts` documents the required posting event, source
state, allowed links, and double-count group for future producers. The validation
trigger rejects `employee_cash_custody` itself and unknown source contracts.
Existing `project_costs` rows are preserved with unique `legacy:` references.

## Advisor classification

New foreign-key lookup columns have covering indexes. Index names are unique.
Safe read RPCs avoid direct financial table policies, so the new tables do not
introduce permissive RLS or auth init-plan findings. Financial budget tables are
not added to `supabase_realtime`; the safe signal is an intentional design.
Unused-index warnings immediately after migration are expected and must not be
used to remove required FK/ordering/approval indexes.

The pre-migration live Advisor snapshot was also reviewed. Because migration
`003` is intentionally not applied by this PR, it contains no budget-object
findings. Its existing results are legacy/out of scope: 92 security notices and
136 performance notices, including existing asset/function warnings, 75
unindexed foreign keys, seven auth init-plan warnings, 43 unused indexes, and 11
multiple-permissive-policy warnings. The indexes added by migration `002` appear
as unused immediately after creation and are intentionally retained.

Warnings on Profiles, Expenses, Employees, Payroll, Assets, or other legacy
objects are unrelated to this migration and remain outside this sprint.

## Known limitations

- Actual-versus-Estimated comparison is not implemented.
- No Employee Cash Custody, Purchase Request, Cost Center, Petty Cash, Supplier
  Invoice, GL, AR, AP, MRP, or Factory Labor allocation module is implemented.
- Template editing uses the protected create-from-approved flow; a future
  template administration screen may add richer maintenance.
- Live integration and Advisor validation require applying migration `003` to a
  non-production Supabase environment. This migration is not auto-applied.
