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
| Expenses | Expense posting | Mapped Expense / asset + VAT Input when applicable | Bank/Cash or Payable according to source settlement state | On protected expense posting/approval | Source reversal | Expense category, VAT, cash/payable mappings | None before activation |
| Inventory | Project / production material issue | Project/Production Cost or WIP | Inventory | When the inventory issue posts | Reverse/adjust inventory source movement | Inventory + project/production/WIP mapping | None before activation |
| Inventory | Inventory adjustment | Mapped inventory gain/loss account or Inventory | Inventory or mapped gain/loss account | When approved count/adjustment posts | Opposite source adjustment | Inventory + adjustment mappings | None before activation |
| Cash | Bank/Cash transfer | Destination Bank/Cash | Source Bank/Cash | When transfer is posted | Source transfer reversal | Source/destination account mappings | None before activation |
| Production | Material issue to production | Production WIP | Inventory | When production issue posts | Reverse source issue | WIP + Inventory | None before activation |
| Production | Production completion | Finished Goods / Inventory | Production WIP | When completion quantity/cost is finalized | Reverse/correct source completion | FG/Inventory + WIP | None before activation |
| Production | Labor / overhead absorbed to production | Production WIP | Payroll/Labor Payable or configured absorption/clearing account | When the canonical production cost event is posted | Source reversal/correction | WIP + labor/overhead mappings | None before activation |
| Payroll | Payroll accrual | Payroll Expense | Payroll Payable, with approved employee-receivable recoveries reducing the mapped Employee Advances/Receivable asset within the same balanced payroll journal | On payroll posting/approval, not draft creation | Payroll source reversal/recalculation contract | Payroll Expense, Payroll Payable, Employee Advances/Receivable | None before activation |
| Payroll | Payroll payment | Payroll Payable | Bank/Cash | When payroll is marked paid | Source payment reversal | Payroll Payable + Bank/Cash | None before activation |
| Daily labor | Labor accrual | Daily Labor Expense | Daily Labor Payable | When the payable labor batch is approved | Source accrual reversal | Daily Labor Expense + Payable | None before activation |
| Daily labor | Labor payment | Daily Labor Payable | Bank/Cash | When labor payment posts | Source payment reversal | Daily Labor Payable + Bank/Cash | None before activation |
| Rentals | Rental revenue/customer charge | Accounts Receivable | Rental Revenue | When the rental charge becomes financially due/posted | Source cancellation/reversal | AR + Rental Revenue | None before activation |
| Assets / Tools | Financially valued asset loss / maintenance | Mapped loss/maintenance expense | Relevant asset/tool control account or payable/cash as defined by the source event | Only when the source event carries a financial valuation | Source event reversal/correction | Asset/tool + loss/maintenance/payable/cash mappings | None before activation |
| Opening | Opening balance journal | Explicit debit lines | Explicit credit lines | Owner-created opening JE on/after accounting activation strategy | Normal opening-JE reversal/correction controls | Opening Balance Equity and chosen posting accounts | Explicit only; never auto-backfilled |

## Current implementation status

- Foundation / COA / Journal / Period Controls: implemented.
- Ledger / Trial Balance / Balance Sheet: implemented.
- Mapping catalog/workspace: implemented.
- Cash & advance integration: in progress.
- Procurement, Sales, Inventory, Production, Expenses, Payroll, Daily Labor, Rentals, Assets: planned from this matrix and must be implemented module-by-module after inspecting each canonical source.
