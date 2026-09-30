# NextEP Accounting Integration Matrix

Status: implementation contract for the additive GL integration.

## Global rules

- The operational module remains the canonical business source. The GL is a derived accounting layer; it must never become a second operational source.
- Every financial source event posts at most one active system journal revision through `accounting_source_links`.
- No historical operational row is auto-posted. Existing rows remain untouched.
- Auto-posting is gated by `accounting_settings.enabled` and `activation_date`. A business date before the activation date is outside GL scope.
- Once an event is in GL scope, missing mappings, an unavailable posting account, or a closed accounting period must fail the business transaction atomically rather than leave operations and GL inconsistent.
- Account IDs are configurable through accounting mappings. Integration code must not hard-code generated account UUIDs.
- Reversal is source-driven. A source reversal reverses the linked journal using the journal's current posted lines, including any audited Owner/Master edit.
- Posted system journals are not reversed manually from the journal workspace; the operational source owns their reversal.
- Owner/Master posted-journal edits change the live GL and therefore ledgers/reports immediately, while preserving revision history and audit data.
- `project_actual_cost_entries` stays managerial/project-cost reporting data unless a specific matrix row names the originating operational event as the canonical GL source. It must not double-post an already-accounted event.
- Opening balances enter only through explicit opening journals. There is no automatic historical backfill.

## Event matrix

| Area | Canonical event | Debit | Credit | Posting timing | Reversal / correction | Configuration | Historical impact |
|---|---|---|---|---|---|---|---|
| Procurement | Goods receipt | Inventory / received asset | GRNI | When the goods receipt becomes financially posted | Reverse from the goods-receipt source using current linked journal lines | Inventory + GRNI mappings | None before activation |
| Procurement | Supplier invoice approval | GRNI and/or mapped expense/asset + VAT Input + supported price variance | Accounts Payable | On invoice approval, after source validation | Source reversal/correction; never a second independent invoice GL path | AP, GRNI, VAT Input, expense/asset/variance mappings | None before activation |
| Suppliers / Cash | Supplier payment — settlement | Accounts Payable | Default Bank/Cash | When classified supplier payment is posted | Source cash reversal | AP + Default Bank/Cash | None before activation |
| Suppliers / Cash | Supplier payment — advance | Supplier Advances | Default Bank/Cash | When classified supplier payment is posted | Source cash reversal after active allocations are reversed | Supplier Advances + Default Bank/Cash | None before activation |
| Suppliers / Cash | Supplier advance allocation | Accounts Payable | Supplier Advances | When an advance is allocated to an approved supplier document | Reverse allocation from source | AP + Supplier Advances | None before activation |
| Sales | Sale / customer charge | Accounts Receivable | Sales Revenue or mapped revenue | When sale becomes financially posted | Source cancellation/reversal | AR + revenue mapping | None before activation |
| Sales / Inventory | Sale inventory issue | COGS | Finished Goods / Inventory | When the stock issue for the sale is posted | Reverse source stock issue | COGS + Inventory/FG mapping | None before activation |
| Customers / Cash | Customer receipt — settlement | Default Bank/Cash | Accounts Receivable | When classified customer receipt is posted | Source cash reversal | Default Bank/Cash + AR | None before activation |
| Customers / Cash | Customer receipt — advance | Default Bank/Cash | Customer Advances | When classified customer receipt is posted | Source cash reversal after active allocations are reversed | Default Bank/Cash + Customer Advances | None before activation |
| Customers / Cash | Customer advance allocation | Customer Advances | Accounts Receivable | When an advance is allocated to a valid customer charge | Reverse allocation from source | Customer Advances + AR | None before activation |
| Customers | Non-cash customer adjustment | Mapped discount / tax / charge account by adjustment type | Accounts Receivable, or inverse for debit adjustments | When protected adjustment posts | Source adjustment reversal | Adjustment-type mappings | None before activation |
| Expenses | Expense posting (current gross spent-expense source) | Expense Default | Default Bank/Cash | When `post_expense` inserts the expense | `cancel_expense` reverses the linked journal; Project Actual Cost remains managerial only | Expense Default + Default Bank/Cash mappings | None before activation |
| Inventory | Project material issue (non-production) | Project Cost or mapped WIP | Inventory | When the project inventory issue posts | Reverse from the project inventory source movement | Inventory + Project Material Cost mapping | None before activation |
| Inventory | Inventory adjustment | Mapped inventory gain/loss account or Inventory | Inventory or mapped gain/loss account | When approved count/adjustment posts | Opposite source adjustment | Inventory + adjustment mappings | None before activation |
| Cash | Bank/Cash transfer | No automatic GL — there is no canonical Bank/Cash transfer transaction in the current operational model | No automatic GL | Not applicable until a real Bank/Cash transfer source exists | Not applicable | Future source/destination financial-account mappings when the operational source exists | No current or historical auto-posting |
| Production | Material issue to production | Production WIP | Inventory | When production issue posts | Reverse source issue | WIP + Inventory | None before activation |
| Production | Production completion | Finished Goods / Inventory | Production WIP, plus mapped production-cost variance when required | When the canonical production receipt finalizes quantity and cost | Source is currently operationally immutable after completion; no silent GL reversal/edit. A future operational completion-correction contract is required before completed-order reversal is supported | FG/Inventory + WIP + Production Cost Variance | None before activation |
| Production | Labor / overhead absorbed to production | Production WIP | Configured labor / overhead clearing accounts | At the canonical production receipt because the current operational model has no separate labor/overhead posting event | Completion is currently operationally immutable; correction follows any future source-level completion correction contract | WIP + labor/overhead clearing mappings | None before activation |
| Payroll | Payroll accrual | Payroll Expense | Payroll Payable + Employee Advances/Receivable recovery + configurable Payroll Deductions Clearing when applicable | When `review_payroll(..., approve=true)` moves draft/rejected to approved; never at draft creation | Approved/paid payroll is currently operationally immutable; review recalculation happens before approval, so no artificial post-approval reversal API is introduced | Payroll Expense + Payroll Payable + Employee Advances/Receivable + Payroll Deductions Clearing | None before activation |
| Payroll | Payroll payment | Payroll Payable | Default Bank/Cash | When `mark_payroll_paid` moves approved to paid, and only if the payroll already has an active accrual GL link | Paid payroll is currently operationally immutable; no artificial payment-reversal API is introduced | Payroll Payable + Default Bank/Cash | None before activation |
| Daily labor | Labor accrual | Daily Labor Expense | Daily Labor Payable + configurable Daily Labor Deductions Clearing when applicable | When `review_daily_labor(..., approve=true)` moves draft to approved | Rejected shifts may be corrected before approval; approved/paid shifts are currently operationally immutable, so no artificial reversal API is introduced | Daily Labor Expense + Daily Labor Payable + Daily Labor Deductions Clearing | None before activation |
| Daily labor | Labor payment | Daily Labor Payable | Default Bank/Cash | When `pay_daily_labor` marks an approved shift paid, and only if an active accrual GL link already exists | Paid shifts are currently operationally immutable; no artificial payment-reversal API is introduced | Daily Labor Payable + Default Bank/Cash | None before activation |
| Rentals | Rental revenue/customer charge | Accounts Receivable | Rental Revenue | When `post_rental` creates an active rental with a positive rental fee | `cancel_rental` reverses the linked revenue journal; rental issue/return remains operational custody only and does not create COGS | Accounts Receivable + Rental Revenue | None before activation |
| Assets / Tools | Asset registry creation/update, assignment, return, and quantity-only movement | No automatic GL | No automatic GL | Operational/master-data only. `assets.purchase_cost` is registry metadata, not a purchase/payment transaction | No accounting reversal because no automatic journal exists | None | Never auto-posted; use explicit opening/manual journals when an opening carrying value is required |
| Assets / Tools | Approved valued asset settlement | Asset Loss Expense | Asset Control | When `approve_asset_settlement(..., approve=true)` moves a pending settlement to approved and `estimated_loss > 0` | Approved settlements are currently operationally immutable; no artificial post-approval reversal API is introduced | Asset Loss Expense + Asset Control | None before activation |
| Assets / Tools | Completed maintenance actual cost | Asset Maintenance Expense | Configurable Asset Maintenance Credit (liability or cash/bank asset according to policy) | When `complete_asset_maintenance` moves an open order to completed and `actual_cost > 0` | Cancelling an open maintenance order has no GL because estimates are not posted; completed maintenance is currently immutable | Asset Maintenance Expense + Asset Maintenance Credit | None before activation |
| Opening | Opening balance journal | Explicit debit lines | Explicit credit lines | Owner-created opening JE on/after accounting activation strategy | Normal opening-JE reversal/correction controls | Opening Balance Equity and chosen posting accounts | Explicit only; never auto-backfilled |

## Current implementation status

- Foundation / COA / Journal / Period Controls: implemented.
- Ledger / Trial Balance / Balance Sheet: implemented.
- Mapping catalog/workspace: implemented.
- Cash & advance integration: implemented.
- Procurement receipt / supplier-invoice integration: implemented.
- Sales customer-charge / sale-inventory integration: implemented.
- Inventory project-issue / adjustment integration: implemented.
- Production material-issue / completion integration: implemented.
- Expense operational integration: implemented.
- Payroll approval/payment integration: implemented.
- Daily Labor approval/payment integration: implemented.
- Rental customer-charge / cancellation integration: implemented.
- Asset valued-settlement / maintenance integration: implemented.
- All Integration Matrix modules above now have an explicit accounting behavior, including operations intentionally defined as no automatic GL.
- Bank/Cash transfer is documented as a future/no-source case: the current app has inventory warehouse transfers, but no canonical financial Bank/Cash transfer transaction. No GL is invented until such an operational source exists.
