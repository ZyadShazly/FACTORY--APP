# NextEP Pilot Acceptance — July 2026

## Goal
Validate the latest merged `main` as one complete product before pilot use.

## Required boundaries
- Authentication, profile bootstrap, roles, and navigation.
- Projects, budgets, milestones, members, files, and actual costs.
- Procurement, receiving, supplier invoices, inventory, warehouses, and production.
- Employees, work schedules, payroll, external labor, and project-cost posting.
- Assets, custody issue/return/settlement, WhatsApp confirmation, and alerts.
- Reporting, Excel workbooks, print/PDF, audit, settings, and realtime refresh.

## Safety rules
- No destructive schema change or production-data reset.
- Database smoke data must be created inside rollback-safe transactions.
- Existing approved, paid, posted, issued, received, and historical records are immutable except through explicit reversal workflows.
- Merge only after repository tests, build, clean-tree checks, Vercel, live integrity checks, and major-boundary regression all pass.

## Status
In progress. This document will be updated with evidence and final pilot decision before merge.
