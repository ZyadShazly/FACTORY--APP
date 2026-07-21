# Inventory Operations Sprint

## Goal
Complete the daily warehouse workflow on top of the existing immutable inventory ledger without replacing or rewriting historical movements.

## Planned scope
- protected warehouse-to-warehouse and location-to-location transfers
- stock count sessions with review and controlled variance posting
- documented positive/negative adjustments with Owner/Manager approval rules
- production material return and damaged/waste movements
- role-aware Inventory workspace actions and clear Arabic feedback
- canonical linkage to Inventory movements and Project Actual Cost where applicable

## Safety constraints
- additive migrations only unless a reviewed defect requires otherwise
- posted inventory movements remain immutable
- no direct client writes to inventory ledger or balances
- no negative stock unless an explicit reviewed policy is introduced
- every correction posts a new movement; historical rows are never edited or deleted
- all smoke data must run inside rollback-safe transactions

## Validation gate
This PR remains Draft until migration review and application to FACTORY APP, live schema and permissions review, rollback-safe smoke tests, full repository tests/build, Vercel checks, and regression across Procurement → Inventory → Production → Actual Cost → Reversal all pass.
