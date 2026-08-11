# Actual Cost Operational Source Integrations

This sprint connects existing operational rows to the protected Project Actual Cost workflow without direct posting.

## Supported sources

- Project-linked material purchases
- Daily labor
- Approved or paid payroll explicitly linked to one project
- Project expenses

## Posting contract

1. An accountant, manager, or owner prepares one Actual Cost entry from the operational source.
2. The entry is created as `submitted` with a globally unique source reference.
3. A manager or owner approves or rejects it through the Actual Cost workflow.
4. Only `approved` entries update `projects.actual_cost`.
5. Reversal returns the operational source state to `reversed` and recalculates the project total.

Cash custody and physical tool custody remain non-expense balances until an approved settlement or consumption line exists.

## Migrations

- `20260719150015_project_actual_cost_source_integrations.sql`
- `20260719150204_project_actual_cost_source_status_hardening.sql`
