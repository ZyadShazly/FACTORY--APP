# UAT Remediation — 2026-08-03

## Governance

- Tracking issue: #118
- Working branch: `uat/fix-all-20260803`
- Merge policy: **blocked until explicit owner approval**
- Data policy: no destructive cleanup or silent rewriting of existing records
- Delivery policy: every defect requires regression coverage and a verification note

## Defect register

| ID | Area | Target outcome | Status |
|---|---|---|---|
| UAT-001 | Inventory | One canonical stock calculation across dashboard and inventory ledger | Root cause confirmed; implementation pending |
| UAT-002 | Projects | One canonical approved actual-cost aggregate across every view/report | Root cause confirmed; implementation pending |
| UAT-003 | Sales | Reject unit price `<= 0` in UI, service/RPC, and database | Fixed on `main` by PR #116; deployment/UAT verification pending |
| UAT-004 | Customers | Classify excess receipt as explicit customer advance | Root cause confirmed; implementation pending |
| UAT-005 | Suppliers | Classify excess payment as explicit supplier advance | Root cause confirmed; implementation pending |
| UAT-006 | Currency | Persist document currency and conversion metadata; render consistently | Open |
| UAT-007 | Reversal | Reliable in-app confirmation, idempotency, retry, and server verification | Partially fixed on `main`; native dialogs remain in production flows |
| UAT-008 | Production | Reject negative quantity/scrap explicitly without coercion | Server rule already rejects negative quantity/waste; UI and deployed-version verification pending |
| UAT-009 | Navigation | Deep-linkable URLs and refresh-safe context | Open |
| UAT-010 | Materials | Unique normalized material identity/code with duplicate warnings | Open |
| UAT-011 | Validation | Shared rules across UI, server, and database | In progress through defect-by-defect reconciliation |
| UAT-012 | Accessibility | Accessible names/tooltips for icon actions | Partially fixed on `main`; full action audit pending |
| UAT-013 | Messaging | Operation-scoped transient status messages | Open |
| UAT-014 | Project reports | Complete the feature or hide it from production navigation | Open |

## Evidence reconciled against `main`

### UAT-001 — dashboard vs inventory material balance

Root cause confirmed in code. The dashboard still calculates raw-material stock locally with the legacy formula:

`initial_stock + materialPurchases - BOM consumption from productionOrders`

The inventory workspace does not use that formula. It loads `get_inventory_workspace()` and renders `balances[].quantity_on_hand`, which is the protected inventory ledger result and includes warehouse movements, opening documents, receipts, issues, transfers, adjustments, counts, and reversals.

Therefore the two screens are reading different accounting models. The dashboard can show a negative or stale quantity even while the inventory ledger shows the correct on-hand balance.

Required implementation:

1. Make the dashboard consume the same canonical inventory balance payload as the inventory workspace.
2. Aggregate ledger balances by inventory item/material across warehouses for the dashboard alert.
3. Show unit, warehouse scope, and last refresh/source label.
4. Remove the legacy `materialStock()` path from dashboard decisions after compatibility verification.
5. Add a regression contract asserting dashboard aggregate equals the sum of `get_inventory_workspace().balances` for each linked material.
6. Preserve unlinked legacy materials as a clearly labelled data-quality warning rather than silently estimating stock.

No production data rewrite is required for this fix.

### UAT-002 — project overview vs actual-cost ledger

Root cause confirmed in code. The project list/card reads the denormalized field `project.actual_cost`, while the project workspace recalculates actual cost by summing `data.projectCosts` for the selected project and grouping those rows by cost type.

This creates two independent sources for the same financial metric:

- Project card / overview source: `projects.actual_cost`
- Project workspace / actual-cost source: `project_costs` rows summed by `project_id`

When the denormalized project column is stale or not refreshed after a new approved cost entry, the overview can show `0` while the ledger and reports show the real total such as `62,364.29`.

Required implementation:

1. Define one canonical approved actual-cost aggregate from `project_costs`.
2. Use that aggregate for project cards, overview KPIs, project detail, reports, variance, profit, and margin.
3. Treat `projects.actual_cost` only as a backward-compatible cache, or remove it from UI reads after compatibility verification.
4. Ensure only approved/posted cost rows enter the canonical total; draft/rejected/cancelled rows must be excluded by the server contract.
5. Refresh the canonical aggregate after every cost mutation, payroll posting, daily-labor settlement, purchase/invoice posting, expense posting, and reversal.
6. Add regression coverage asserting all project surfaces return the same amount for the same project and cost state.
7. Add a reconciliation query/report that flags any mismatch between the cache column and the canonical aggregate before release.

No historical cost rows should be rewritten silently. Any cache backfill must be additive, auditable, and reviewed before production application.

### UAT-003 — negative sale price

PR #116 introduced protected sales/rental lifecycle handling, rejects new negative/incomplete/inconsistent transactions, preserves the existing legacy `-1` sale for controlled cancellation, and added regression coverage. This item must still be re-tested on the preview/live deployment before closure.

### UAT-004 / UAT-005 — customer and supplier advances

Root cause confirmed in code. The UI currently posts every customer receipt directly to `customerReceipts` and every supplier payment directly to `supplierPayments` after checking only that the amount is greater than zero. It does not compare the payment to the current due balance and does not persist a transaction classification.

The ledgers then calculate:

- customer balance = sales + rentals - receipts
- supplier balance = purchases - payments

So a legitimate advance is displayed only as a negative receivable/payable, with no distinction between:

- settlement against an existing due amount
- customer advance / customer deposit
- supplier advance / prepayment

This is not a reason to block advances. The defect is the missing classification and accounting contract.

Required implementation:

1. Add an explicit transaction classification such as `settlement` or `advance` to customer receipts and supplier payments.
2. When the entered amount exceeds the current due balance, show an in-app confirmation that the excess will be recorded as an advance.
3. Split mixed transactions when needed: due settlement portion plus advance portion, or persist both amounts explicitly in one protected RPC result.
4. Present due balance and advance balance separately in customer/supplier cards and ledgers.
5. Keep advances available for later allocation to invoices or purchases through a documented, audited workflow.
6. Add server-side validation and database constraints so clients cannot create an unclassified overpayment directly.
7. Preserve the existing UAT `1` amounts as legacy anomalies for controlled reclassification or reversal; do not silently rewrite them.
8. Add regression tests for zero-due advance, partial settlement, exact settlement, overpayment, later allocation, cancellation, and audit history.

A migration is likely required because the current transaction rows do not carry an explicit classification. It must be additive and backward compatible, and it must not be applied to production without owner review.

### UAT-008 — negative production values

`create_production_order_secure` already rejects `target_quantity <= 0` and rejects negative `target_waste_percentage` on the server. The current React workspace explicitly rejects non-positive quantity, but a dedicated UI check/message for negative waste and deployment verification are still required.

### UAT-007 — reversal/cancellation

Protected RPC-backed cancellation exists for sales, rentals, and production orders, but several flows still use `window.prompt` / `window.confirm`. The remaining work is to replace browser-native dialogs with in-app, busy-safe, retry-aware confirmation while preserving the server-side reversal contract.

## Verification gate

Before this branch can be considered ready for owner review:

1. All relevant automated tests pass.
2. Production build passes.
3. Each defect has a reproducible before/after case.
4. Any migration has rollback/compatibility notes and live verification evidence.
5. Preview deployment is healthy.
6. Manual UAT is repeated on clean or restored data.
7. No merge is performed without explicit approval from the owner.
