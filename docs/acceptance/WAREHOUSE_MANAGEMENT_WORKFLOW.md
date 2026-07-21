# Warehouse Management Workflow Acceptance

- Open warehouse details before editing or archiving.
- Add warehouses and storage locations from the UI.
- Edit warehouse name/code only while preserving historical references.
- Archive warehouses instead of deleting them when balances, movements, receipts, counts, or production links exist.
- Block archive when it would leave active stock without a valid destination.
- Show current balances, locations, recent movements, open counts, and linked receipts before archive.
- Preserve inventory history and prevent orphaned balances or movements.
- Review any additive migration before applying it.
- Run rollback-safe smoke tests, full repository tests/build, Vercel checks, and cross-module regression before merge.
