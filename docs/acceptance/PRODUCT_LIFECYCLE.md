# EP05-C — Product Lifecycle

## Scope

Products become reversible master data: active products can be archived with a
reason and restored, while all production, inventory, sale, and rental history
remains readable.

## Live baseline

- Products: 2
- Both are sale products.
- Both currently use SKU `1`; this pre-existing duplicate is preserved and is
  not silently rewritten by this lifecycle unit.

## Contract

- Direct product deletion is blocked by trigger, RLS policy removal, and table
  grant removal.
- Production-order and finished-goods-review foreign keys change from cascade
  to restrict.
- Archive and restore require manager-level delete authorization, a reason,
  server time, and authenticated actor.
- Archived products remain visible in collapsed history but are excluded from
  new sales, rentals, and production orders.
- Database reference guards enforce the selector behavior independently of UI.
- Existing inventory links and all historical names remain intact.

## Verification

- Migration: `20260803073000_product_lifecycle.sql`
- Regression: `product-lifecycle.test.mjs`
- Required before completion: full tests, build, Quality Gate, Vercel, live
  migration, delete probe, count reconciliation, FK verification, and Advisors.
