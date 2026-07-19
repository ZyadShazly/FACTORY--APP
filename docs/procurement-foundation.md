# Procurement foundation

This sprint introduces the additive Procure-to-Pay data model for purchase requests, supplier quotations, purchase orders, goods receipts, and supplier invoices.

## Safety model

- Existing operational and accounting rows are not rewritten.
- All procurement tables have row-level security enabled.
- Direct access for `anon` and `authenticated` is revoked; workflow access is added only through reviewed RPCs.
- Project, budget item, milestone, supplier, material, and Actual Cost links use restrictive or nullable foreign keys to preserve history.

## Planned workflow

1. Create and submit a purchase request.
2. Collect and compare supplier quotes.
3. Select a quote and create an approved purchase order.
4. Confirm full or partial goods receipts.
5. Match a supplier invoice against the order and receipt.
6. Post approved project costs through the protected Actual Cost workflow.
