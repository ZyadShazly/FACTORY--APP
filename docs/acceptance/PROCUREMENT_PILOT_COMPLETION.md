# Phase 2 — Procurement Pilot Completion

Draft PR: [#86](https://github.com/ZyadShazly/FACTORY--APP/pull/86)

## Outcome

The procurement workspace now presents one workflow step at a time:

`Purchase Request → Approval → Supplier Quote → Draft Purchase Order → Preview → Approval → Print → Send → Goods Receipt → Supplier Invoice → Completion`

The implementation reuses the two commits from open Draft PR #80 and completes their UI, migration, audit, print, and regression contracts. PR #80 was not modified, closed, or merged.

## User experience

- A user-facing display name is required for new purchase requests and draft purchase orders.
- Internal PR/PO serials remain visible as secondary references.
- Requests and orders are split into active work and collapsed history.
- Converted requests remain immutable history; no conversion path deletes them.
- Five focused tabs replace the previous all-at-once workspace.
- The single sticky primary action is **New Purchase Request**.
- Four useful KPI cards are shown.
- Draft PO intent is explained in Arabic.
- Request and PO approval, PO sending, and rejection all happen from a full document preview.
- Friendly Arabic mappings cover missing names, invalid workflow states, duplicate quote conversion, missing items, receiving state, permission failures, and invoice/order mismatch.
- The configured system currency is used for procurement input and money formatting; `SAR` is no longer hardcoded in this workspace.

## Document templates

The shared preview/print contract supports:

1. Purchase Request
2. Purchase Order
3. Goods Receipt
4. Supplier Invoice

Each template includes the NextEP logo, display name where applicable, internal document number, project, supplier, item lines, quantities, unit prices, discounts, VAT, totals, status, and preparation/review/approval signature areas. The A4 RTL print stylesheet isolates the selected document, repeats table headers, prevents row/signature splitting, and removes application layout height to prevent trailing blank pages.

## Migration review

Migration: `202607260002_procurement_review_send_workflow.sql`

Status: **Created only; not applied to production or any connected Supabase project.**

- Additive `display_name`, send actor/time/reference columns only.
- Existing rows are backfilled from the first item description, then internal serial.
- Backward-compatible defaults keep the legacy PR and PO RPCs insertable.
- `save_purchase_request_v2` wraps the protected legacy save contract and adds naming/audit atomically.
- Legacy RPCs remain available.
- Draft creation, PO approval, PO rename, and PO send remain role-checked, row-locked, and audited.
- `sent_by` has a partial covering index.
- Procurement audit lookup has a bounded partial index.
- The protected workspace RPC now returns PO audit history and explicit capabilities.
- All new RPCs revoke `public`/`anon` and grant only `authenticated`.
- RLS, table revokes, Actual Cost posting, receipt atomicity, and current data are unchanged.

## Bug traceability

| Bug | Fix evidence | Automated coverage | UAT status |
| --- | --- | --- | --- |
| E — Procurement request clutter | Focused tabs, primary display names, active-first sections, collapsed request/order history, preview-only approval/send | `procurement-request-lifecycle-ui.test.mjs`, `procurement-status-board-layout.test.mjs`, `procurement-review-send-workflow.test.mjs` | Contract passed; visual QA pending preview |
| F — Printing | Four shared professional templates, A4 RTL isolation, logo, VAT, totals, signatures, blank-page prevention | `procurement-document-review.test.mjs`, `procurement-printing.test.mjs` | Contract passed; print-dialog UAT pending preview |
| J — Currency in procurement | Configured currency code and formatter replace hardcoded `SAR` | `procurement-document-review.test.mjs` | Passed for procurement scope |
| P — Global UX confusion in procurement | One tab/job, one primary action, four KPIs, archive collapsed, details on demand | `procurement-status-board-layout.test.mjs` | Contract passed; visual QA pending preview |
| Q — Friendly procurement errors | Explicit Arabic mapping for new and existing procurement workflow failures | `procurement-review-send-workflow.test.mjs` plus full regression | Passed for mapped procurement states |

## Validation

| Check | Result |
| --- | --- |
| Focused procurement tests | 30 passed, 0 failed |
| Full repository tests | 309 passed, 0 failed, 2 intentional environment-gated skips; 311 total |
| Package build script | Passed; 2,398 modules transformed |
| `git diff --check` | Passed |
| Build artifact cleanliness | Passed |
| AppMonolith scope | No AppMonolith change |
| Migration application | Not run |
| Desktop / mobile / RTL | Automated responsive/RTL contracts passed; live preview QA pending |
| Remote quality gate | Passed on Draft PR #86 |
| Vercel | Passed on Draft PR #86 |

The existing large AppMonolith chunk warning remains unchanged and outside this phase’s procurement scope.
