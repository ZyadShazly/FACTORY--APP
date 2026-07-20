# Reporting & Analytics Sprint Scope

## Goal
Build a protected reporting foundation on the latest merged main without duplicating operational data or weakening module permissions.

## Initial scope
- shared KPI definitions for Projects, Procurement, Inventory, Production, Actual Cost, Payroll, and Custody
- protected read models/RPCs instead of direct access to restricted operational tables
- consistent date, currency, empty, loading, and permission states
- rollback-safe validation against existing operational records

## Safety constraints
- additive migrations only
- no destructive denormalization or historical rewrites
- no report may bypass source-module authorization
- no merge until schema/permission review, rollback-safe smoke tests, repository tests/build, Vercel checks, and major-boundary regression pass

## First preflight
Inspect existing report pages, dashboard queries, views, and RPCs before designing any migration.