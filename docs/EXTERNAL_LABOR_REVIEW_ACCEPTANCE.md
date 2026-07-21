# External Labor Review Acceptance

## Required workflow

- Open every shift before payment.
- Show worker, project, trade, supervisor/source, shift times, break, regular hours, overtime, rates, calculation, notes, and payment history.
- Require review before payment.
- Allow rejection with a mandatory reason.
- Prevent deleting reviewed or paid shifts; use reversal/correction workflows instead.
- Preserve historical amounts and project-cost links.

## Safety

- Existing paid shifts remain unchanged.
- No destructive migration.
- New controls are additive and enforced in the database.
- Smoke tests must run in a transaction and roll back.
