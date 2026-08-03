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
| UAT-001 | Inventory | One canonical stock calculation across dashboard and inventory ledger | Open |
| UAT-002 | Projects | One canonical approved actual-cost aggregate across every view/report | Open |
| UAT-003 | Sales | Reject unit price `<= 0` in UI, service/RPC, and database | Open |
| UAT-004 | Customers | Classify excess receipt as explicit customer advance | Open |
| UAT-005 | Suppliers | Classify excess payment as explicit supplier advance | Open |
| UAT-006 | Currency | Persist document currency and conversion metadata; render consistently | Open |
| UAT-007 | Reversal | Reliable in-app confirmation, idempotency, retry, and server verification | Open |
| UAT-008 | Production | Reject negative quantity/scrap explicitly without coercion | Open |
| UAT-009 | Navigation | Deep-linkable URLs and refresh-safe context | Open |
| UAT-010 | Materials | Unique normalized material identity/code with duplicate warnings | Open |
| UAT-011 | Validation | Shared rules across UI, server, and database | Open |
| UAT-012 | Accessibility | Accessible names/tooltips for icon actions | Open |
| UAT-013 | Messaging | Operation-scoped transient status messages | Open |
| UAT-014 | Project reports | Complete the feature or hide it from production navigation | Open |

## Verification gate

Before this branch can be considered ready for owner review:

1. All relevant automated tests pass.
2. Production build passes.
3. Each defect has a reproducible before/after case.
4. Any migration has rollback/compatibility notes and live verification evidence.
5. Preview deployment is healthy.
6. Manual UAT is repeated on clean or restored data.
7. No merge is performed without explicit approval from the owner.
