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
| UAT-002 | Projects | One canonical approved actual-cost aggregate across every view/report | Investigating |
| UAT-003 | Sales | Reject unit price `<= 0` in UI, service/RPC, and database | Fixed on `main` by PR #116; deployment/UAT verification pending |
| UAT-004 | Customers | Classify excess receipt as explicit customer advance | Open |
| UAT-005 | Suppliers | Classify excess payment as explicit supplier advance | Open |
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

### UAT-003 — negative sale price

PR #116 introduced protected sales/rental lifecycle handling, rejects new negative/incomplete/inconsistent transactions, preserves the existing legacy `-1` sale for controlled cancellation, and added regression coverage. This item must still be re-tested on the preview/live deployment before closure.

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
