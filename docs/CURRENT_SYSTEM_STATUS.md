# NEXTEP ERP — Current System Status

> **Authority:** current operational baseline and execution-plan index
>
> **Snapshot date:** 2026-08-02
>
> **Repository:** `ZyadShazly/FACTORY--APP`
>
> **Baseline:** `origin/main` at
> `8e7d9496d0f55060dae3f35a60d5d597d9bcd3b3`

This document supersedes status claims in older sprint trackers. It does not
delete or rewrite their historical evidence.

## Source-of-truth order

When sources disagree, use this order:

1. the current `origin/main` tree and the live `FACTORY APP` Supabase schema;
2. current GitHub PR, Quality Gate, and Vercel state;
3. product and safety rules in `MASTER_ROADMAP.md` and
   `PILOT_ACCEPTANCE_2026-07.md`;
4. module acceptance documents as delivery evidence;
5. historical trackers and sprint plans as point-in-time records only.

## Current release baseline

| Item | Current state |
| --- | --- |
| `main` | `8e7d9496d0f55060dae3f35a60d5d597d9bcd3b3` |
| Latest merged change | PR #102 — reconcile current system baseline |
| Quality Gate | Passed on the current `main` SHA |
| Vercel | Passed on the current `main` SHA |
| Former Full Pilot PRs | #84–#91 are merged |
| Historical conflict PRs | #34 and #80 are closed without merge |
| Open PR | EP-01 Draft branch only; PR #99 is closed without merge |
| Live Supabase project | `FACTORY APP` / `cyjtbbkurmqyohbdmhbq` / `ACTIVE_HEALTHY` |

The local branch from which this status reconciliation started was an old
Phase 7 branch. Future implementation branches must be created from the latest
`origin/main`, never from that historical branch.

## Documentation classification

| Document | Classification | Use |
| --- | --- | --- |
| `CURRENT_SYSTEM_STATUS.md` | Current authority | Operational status, migration map, execution sequence |
| `MASTER_ROADMAP.md` | Policy authority, status details dated 2026-07-15 | Product principles, Definition of Ready/Done, governance |
| `PILOT_ACCEPTANCE_2026-07.md` | Current safety/acceptance reference | Non-destructive rules and pilot boundaries |
| Module acceptance files | Delivery evidence | What a merged unit intended and validated |
| `FULL_PILOT_HARDENING_TRACKER.md` | Historical record | Point-in-time evidence while PRs #84–#91 were Draft |
| Former Phase 0–15 mission plan | Historical record | Must not be used as the remaining implementation queue |
| README migration order before EP-00 | Superseded | Ended at `202607160001` and did not reflect current main |

## Current implementation matrix

| Domain | State on current `main` | Remaining decision |
| --- | --- | --- |
| Baseline and CI | Stable | Preserve clean test/build behavior |
| Design system | Foundation merged | Adopt only inside bounded module work |
| Procurement | Workflow implemented | Reconcile repository lifecycle timestamps with live status-history model |
| Inventory | Workflow and explicit item type implemented | Keep one classification contract; close superseded alternative |
| Production | Protected workflow implemented | End-to-end regression only |
| Projects | Protected lifecycle implemented | Reconcile one live execution-without-approval record |
| Employees | Unit lifecycle implemented | Global dependency framework is not independently implemented |
| Payroll | Review/approval/payment implemented | End-to-end regression only |
| External labor | Review/payment foundation only | Additions, deductions, net settlement, correction, and archive UX remain |
| Assets | Custody foundation is extensive | Maintenance boundary, focused UX, link UAT, and targeted indexes remain |
| Expenses | Basic direct CRUD plus cost-source fields | Protected financial lifecycle and reversal are required |
| Products/Sales/Suppliers/Customers | Legacy CRUD | Archive, reversal, and dependency-safe lifecycle are required |
| Reporting/exports | Reporting foundation exists | Currency, PDF, permissions, and artifact QA remain |
| Error/dependency UX | Partial | Raw database messages and destructive legacy paths remain |
| Full pilot acceptance | Not complete | Must run after remaining financial and commercial contracts stabilize |

## Inventory item classification contract

The only authoritative classification field is:

```text
public.inventory_items.item_type
```

Allowed values:

- `raw_material`
- `finished_good`

Repository migration:

```text
supabase/migrations/202607290003_explicit_inventory_item_type.sql
```

Live migration:

```text
20260729082906 explicit_inventory_item_type
```

The UI reads `item.item_type`, creates records through
`create_inventory_item_typed`, and retains the raw-material type when a material
link is removed. A second column or contract named `stock_kind` would create two
sources of truth and must not be introduced.

## Draft PR #99 disposition

**Recommendation: close as superseded; do not merge.**

PR #99 contains three changes:

1. a new `inventory_items.stock_kind` column and trigger;
2. UI changes from the merged `item_type` contract to `stock_kind`;
3. two source-contract regression tests for that alternative field.

The same product intent is already present on `main` through merged PR #100:

- `item_type` is persisted independently from material/product links;
- constraints prevent incompatible link/type combinations;
- `create_inventory_item_typed` accepts an explicit type;
- the catalog and regression tests use the explicit type;
- the live database contains `inventory_items.item_type`;
- live migration `20260729082906 explicit_inventory_item_type` is recorded.

PR #99 has no unique applicable behavior that is absent from the merged
contract. Its UI patch would also remove the current inventory concept guide and
unlinked-material guidance. Merging it would add a competing schema field and
regress current UX.

## Safe Delete status

`origin/agent/safe-delete-dependency-explorer` points to
`e1ccd8ae448fd05e6490c767ad07b1a4cf6954a7`, is already an ancestor of
`main`, and has no unique diff against `main`.

Therefore:

- there is no independent global Safe Delete implementation waiting to merge;
- employee-specific dependency evidence and checked deletion already exist;
- Production uses cancellation/reversal rather than deletion;
- remaining commercial and financial domains must add dependency-safe lifecycle
  behavior inside their own bounded contracts;
- future documentation must not describe the branch as external work that
  blocks all dependency handling.

## Repository-to-live migration map

### Interpretation rules

- The repository filename is the review and replay identity.
- The live `version` is the identity stored in
  `supabase_migrations.schema_migrations`.
- Matching semantic names with different versions indicate application through
  a generated live timestamp.
- A missing matching name does **not** prove the database object is absent.
- No migration in this table should be reapplied solely because its repository
  version is not present in live history.

### Semantic matches with generated live versions

| Repository migration | Live version/name |
| --- | --- |
| `2026071900029_project_estimated_budget_preflight` | `20260719110339 project_estimated_budget_preflight` |
| `202607190003_project_estimated_budget` | `20260719111053 project_estimated_budget` |
| `202607190004_project_estimated_budget_security_accounting_hardening` | `20260719111133 project_estimated_budget_security_accounting_hardening` |
| `202607190005_supabase_policy_cleanup` | `20260719112820 supabase_policy_cleanup` |
| `202607190006_project_actual_cost_engine` | `20260719124029 project_actual_cost_engine` |
| `202607190007_project_actual_cost_engine_hardening` | `20260719124056 project_actual_cost_engine_hardening` |
| `202607190008_project_actual_cost_source_controls` | `20260719124445 project_actual_cost_source_controls` |
| `202607190009_project_actual_cost_workflow_variance` | `20260719134651 project_actual_cost_workflow_variance` |
| `202607190010_project_actual_cost_source_integrations` | `20260719150015 project_actual_cost_source_integrations` |
| `202607190011_project_actual_cost_source_status_hardening` | `20260719150204 project_actual_cost_source_status_hardening` |
| `202607190012_procurement_foundation` | `20260719151717` and `20260719153729 procurement_foundation` |
| `202607190013_procurement_workflow` | `20260719154134 procurement_workflow` |
| `202607190014_procurement_security_hardening` | `20260719154209 procurement_security_hardening` |
| `202607190015_procurement_invoice_accounting_hardening` | `20260719154406 procurement_invoice_accounting_hardening` |
| `202607190014_inventory_foundation` | `20260719171953 inventory_foundation` |
| `202607190015_inventory_reversal_hardening` | `20260719172014 inventory_reversal_hardening` |
| `202607190016_inventory_cost_link_guard` | `20260719172213 inventory_cost_link_guard` |
| `202607190017_inventory_cost_link_scope` | `20260719172259 inventory_cost_link_scope` |
| `202607190020_system_ux_hardening` | `20260719185315 system_ux_hardening` |
| `202607190021_system_ux_hardening_rpc_acl` | `20260719185436 system_ux_hardening_rpc_acl` |
| `202607200001_production_manufacturing_foundation` | `20260720074356` and `20260720074617 production_manufacturing_foundation` |
| `202607200002_production_operation_workflow` | `20260720074615` and `20260720074747 production_operation_workflow` |
| `202607200003_production_operation_parameter_fix` | `20260720075127 production_operation_parameter_fix` |
| `202607200004a_operational_workspace_reads` | `20260720094733 operational_workspace_reads` |
| `202607200004b_secure_production_create` | `20260720094749 secure_production_create` |
| `202607200004c_production_action_permissions` | `20260720094822 production_action_permissions` |
| `202607200004d_operation_parameter_disambiguation` | `20260720095026 operation_parameter_disambiguation` |
| `202607200004e_workspace_project_name_fix` | `20260720095154 workspace_project_name_fix` |
| `202607200004f_procurement_workspace_v2` | `20260720100200 procurement_workspace_v2` |
| `202607200014_procurement_inventory_atomic_receipt` | `20260720101618 procurement_inventory_atomic_receipt` |
| `202607200001_operational_bug_closure` | `20260720111024 operational_bug_closure` |
| `202607200007_reporting_analytics_foundation` | `20260720162105 reporting_analytics_foundation` |
| `202607200008_action_center_search` | `20260720201614 action_center_search` |
| `202607200009_asset_alerts_security_invoker` | `20260720211345 asset_alerts_security_invoker` |
| `202607210001_inventory_operations` | `20260720231743 inventory_operations` |
| `202607210002_inventory_operations_hardening` | `20260720231753 inventory_operations_hardening` |
| `202607210004_fix_pending_asset_cancellation` | `20260721062000 fix_pending_asset_cancellation` |
| `202607210005_pilot_uat_alerts_calendar` | `20260721071818 pilot_uat_alerts_calendar` |
| `20260721090000_employee_whatsapp_assets` | `20260721081800` and `20260721081941 employee_whatsapp_assets` |
| `20260721093000_employee_whatsapp_reconcile` | `20260721083301 employee_whatsapp_reconcile` |
| `20260721100000_employee_management_workflow` | `20260721095523 employee_management_workflow` |
| `20260721101000_employee_delete_guard_reconcile` | `20260721095949 employee_delete_guard_reconcile` |
| `20260721102000_payroll_review_workflow` | `20260721103320 payroll_review_workflow` |
| `202607210003_external_labor_review_workflow` | `20260721151650 external_labor_review_workflow` |
| `20260721164000_external_labor_payment_parameter_fix` | `20260721161457 external_labor_payment_parameter_fix` |
| `202607212220_work_schedule_review_and_cancellation` | `20260721191416 work_schedule_review_and_cancellation` |
| `202607220001_warehouse_management_workflow` | `20260721231749 warehouse_management_workflow` |
| `202607220001_pilot_security_permission_cleanup` | `20260722011940 pilot_security_permission_cleanup` |
| `202607220002_pilot_security_public_grant_cleanup` | `20260722012034 pilot_security_public_grant_cleanup` |
| `20260726103045_inventory_setup_opening_balance` | `20260726181811 inventory_setup_opening_balance` |
| `20260727053000_production_partial_material_issue` | `20260727070553 production_partial_material_issue` |
| `202607280005_stock_production_and_inventory_split` | `20260728103459 stock_production_and_inventory_split` |
| `202607280006_finished_goods_production_receipt` | `20260728114535 finished_goods_production_receipt` |
| `202607290001_automatic_finished_goods_linking` | `20260729063300 automatic_finished_goods_linking` |
| `202607290002_automatic_raw_material_linking` | `20260729065159 automatic_raw_material_linking` |
| `202607290003_explicit_inventory_item_type` | `20260729082906 explicit_inventory_item_type` |

### Repository files without an exact live-history name

| Repository scope | Current evidence |
| --- | --- |
| `202607130001` through `202607180008` | No matching names in the visible live history; core identity, payroll calendar, Assets, and Realtime objects are live. Exact provenance remains an EP-01 reconciliation item. |
| `202607190001_project_workspace_upgrade` | No matching live-history name; Project workspace objects are live. |
| `202607190002_project_workspace_performance_hardening` | No matching live-history name; do not infer missing indexes from history alone. |
| `202607240001_procurement_request_lifecycle` | No exact live-history name. `purchase_request_status_history` is live, while repository-defined `converted_at` and `completed_at` columns are absent. Live history later records `20260729102604 reconcile_purchase_request_status_history`. Canonical lifecycle representation remains an EP-01 decision. |
| `202607260001_inventory_material_catalog` | No exact live-history name; `manage_inventory_item_catalog` is live. |
| `202607260002_procurement_review_send_workflow` | No exact live-history name; reviewed send/display fields and RPC markers are live. |
| `202607280001_production_pilot_completion` | No exact live-history name; assignment and quality markers are live. |
| `202607280002_project_pilot_completion` | No exact live-history name; `get_project_pilot_workflow` and approval fields are live. |
| `202607280003_employee_lifecycle_completion` | No exact live-history name; `employee_dependency_summary` is live. |
| `202607280004_payroll_pilot_completion` | No exact live-history name; review evidence fields and `get_payroll_review_snapshot` are live. |

### Live migration records without an exact repository filename

| Live version/name | Interpretation |
| --- | --- |
| `20260721041533 production_execution_quality` | Historical live implementation later reconciled by the merged Production completion migration |
| `20260721062053 fix_asset_cancel_record_alias` | Live hotfix not represented by an exact repository filename |
| `20260721081835 employee_phone_acl_hardening` | Live hardening entry without an exact repository filename |
| `20260727050420 inventory_setup_opening_balance_reconcile` | Live reconciliation entry without an exact repository filename |
| `20260729052831 fix_finished_goods_uuid_aggregate` | Live hotfix without an exact repository filename |
| `20260729102604 reconcile_purchase_request_status_history` | Live lifecycle reconciliation; not equivalent to blindly applying the older repository migration |

Duplicate semantic names in live history are evidence of repeated/generated
application paths, not permission to delete or rewrite migration history.

## Live integrity snapshot

Read-only checks on 2026-07-30 returned:

| Check | Result |
| --- | ---: |
| Negative inventory quantities | 0 |
| Duplicate Actual Cost source references | 0 |
| Paid payroll without approval | 0 |
| Paid external labor without approval | 0 |
| Completed Production orders with open operations | 0 |
| Non-exempt project execution without recorded project approval | 1 |
| Expenses without a project | 1 |
| Expenses not posted to Actual Cost | 1 |

The two Expense counts may describe the same row; this was not assumed or
modified. These records are EP-01 investigation inputs, not authorization for a
data repair.

## Current execution sequence

The former Phase 0–15 queue is retired. The current sequence is:

1. **EP-00 — Baseline and Governance Reconciliation**: this documentation-only
   baseline.
2. **EP-01 — Live Schema and Data Reconciliation**.
3. **EP-02 — Expenses and Financial Integrity**.
4. **EP-03 — External Labor Settlement**.
5. **EP-04 — Assets Operational Closeout**.
6. **EP-05 — Commercial Lifecycle Hardening**.
7. **EP-06 — Reporting and Export Acceptance**.
8. **EP-07 — Full Pilot Acceptance**.

Each package requires a new branch from the latest `origin/main`, one bounded
Draft PR, focused and full tests, build, clean-tree verification, Quality Gate,
Vercel, and relevant Desktop/Mobile RTL QA. No package authorizes merging,
auto-merge, production migration application, or live-data mutation.

## Deferred work

- broad navigation/help redesign;
- broad `AppMonolith` refactoring or directory renaming;
- full Employee Cash Custody implementation;
- attendance hardware, GPS, face verification, and mobile attendance;
- multi-company and multi-branch architecture;
- removal of newly created or workload-protecting indexes solely because an
  advisor reports them unused.

## EP-01 evidence

The read-only live inspection and its safety decisions are recorded in
[EP-01 Live Schema and Data Reconciliation](EP_01_LIVE_SCHEMA_DATA_RECONCILIATION.md).
It confirms that the two Expense counts refer to one row, adopts immutable
Purchase Request status history as the canonical conversion/completion record,
and identifies one unintended anonymous Inventory RPC grant for bounded
migration hardening.

## Known uncertainties carried beyond the EP-01 snapshot

1. Exact application provenance for live objects whose repository migration name
   is absent from `schema_migrations`.
2. Canonical Purchase Request lifecycle representation: timestamp columns versus
   immutable status-history only.
3. Business context and safe disposition of the one non-exempt project that
   started execution without recorded project approval.
4. Whether the unlinked and unposted Expense counts refer to the same live row.
5. Which Supabase Advisor warnings are intentional RPC-only design and which
   require bounded remediation.
