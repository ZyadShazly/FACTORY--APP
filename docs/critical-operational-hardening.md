# Critical Operational Hardening

This branch freezes roadmap feature work and addresses production-readiness defects in strict severity order.

## Critical gates

1. Production UI must use protected RPC reads and workflow actions only.
2. Production role permissions must be action-based and least-privilege.
3. Inventory balances must come from the protected inventory ledger only.
4. Legacy purchase paths must not bypass Procurement → Goods Receipt → Inventory.
5. Actual Cost must have one canonical posting source per operational event.
6. Database exceptions must be mapped to user-facing messages.
7. Full Project → Procurement → Inventory → Production → Actual Cost → Reversal regression must pass.

No new feature sprint may start until Critical and High defects are closed. No destructive migration or historical rewrite is allowed.