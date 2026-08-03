# EP05-B — Sales and Rental Transaction Lifecycle

## Scope

This bounded unit makes posted sales and rentals immutable and replaces direct
edit/delete with protected return or cancellation actions. Product lifecycle,
customer receipts, supplier payments, invoices, and quotations remain separate
EP05 work.

## Read-only production baseline

- Sales: 2
- Rentals: 0
- One sale is a normal historical row: quantity 10, unit price 10,000, total
  100,000, dated 2026-07-29.
- One legacy sale anomaly exists: quantity 1, unit price -1, total -1, dated
  2026-08-03.

The anomalous row is preserved exactly. This unit does not silently delete,
rewrite, normalize, or classify it. The UI labels it as a legacy record needing
review, while new database checks prevent another negative sale.

## Lifecycle contract

- New sales start as `posted`; posted financial terms are immutable.
- A manager or owner can cancel a sale with a mandatory reason.
- Cancelled sales remain visible but no longer reduce stock or contribute to
  revenue, cost of goods, customer balance, or daily sales.
- New rentals start as `active`; their commercial terms are immutable.
- An authorized Rentals user can mark an active rental returned with a valid
  return date.
- A manager or owner can cancel an active rental with a mandatory reason.
- Returned and cancelled rentals are terminal and immutable.
- Direct UPDATE and DELETE policies are removed from both tables.
- Product and customer foreign keys use `ON DELETE RESTRICT`.

## Data and performance protection

- Additive `NOT VALID` checks protect new rows without rewriting or rejecting
  the preserved legacy anomaly during deployment. Their cancelled-state branch
  also allows the manager to cancel that anomaly without changing its original
  amounts.
- New rows require product, customer, business date, positive quantity,
  non-negative financial values, and consistent sale totals.
- Sales, rentals, customer receipt, and supplier payment foreign keys receive
  covering indexes identified during live Advisor review.

## Verification contract

- Migration: `20260803071500_commercial_transaction_lifecycle.sql`
- Regression: `commercial-transaction-lifecycle.test.mjs`
- Required before completion: full tests, production build, GitHub Quality Gate,
  Vercel, live migration, immutable-delete probes, row-count reconciliation,
  and post-DDL Advisor review.
