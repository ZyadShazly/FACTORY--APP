# FACTORY APP live schema snapshot

Generated from the live Supabase project on 2026-07-21 after PR #41.

## Source of truth

- Project: `FACTORY APP`
- Project ref: `cyjtbbkurmqyohbdmhbq`
- PostgreSQL: 17
- The generated Supabase TypeScript schema was refreshed during this audit.

## Public tables

`asset_assignment_items`, `asset_assignments`, `asset_attachments`, `asset_categories`, `asset_identity_binding_migration_report`, `asset_locations`, `asset_movements`, `asset_realtime_signal`, `asset_return_events`, `asset_return_items`, `asset_settings`, `asset_settlements`, `assets`, `audit_log`, `customer_receipts`, `customers`, `daily_labor`, `departments`, `employees`, `expenses`, `goods_receipt_items`, `goods_receipts`, `holiday_calendar`, `holiday_scopes`, `inventory_balances`, `inventory_count_lines`, `inventory_count_sessions`, `inventory_items`, `inventory_locations`, `inventory_movements`, `inventory_warehouses`, `material_purchases`, `materials`, `payroll`, `production_material_requirements`, `production_operation_events`, `production_order_operations`, `production_orders`, `products`, `profiles`, `project_activities`, `project_actual_cost_allocations`, `project_actual_cost_entries`, `project_budget_items`, `project_budget_sections`, `project_budget_template_items`, `project_budget_template_sections`, `project_budget_templates`, `project_budget_versions`, `project_cost_freezes`, `project_cost_source_contracts`, `project_costs`, `project_files`, `project_members`, `project_milestones`, `project_realtime_signal`, `projects`, `purchase_order_items`, `purchase_orders`, `purchase_request_items`, `purchase_requests`, `rentals`, `sales`, `supplier_invoice_lines`, `supplier_invoices`, `supplier_payments`, `supplier_quote_items`, `supplier_quotes`, `suppliers`, `system_settings`, `work_schedule_days`, `work_schedules`.

## Important current workflow columns

- `employees`: WhatsApp phone normalization and employee-status audit fields.
- `payroll`: review reasons, rejection fields, calendar version/stale fields, approval/payment fields.
- `asset_assignments`: WhatsApp confirmation snapshots, token lifecycle, override/reversal audit fields.
- `work_schedules`: revision, approval, cancellation and version-validity fields.

## Maintenance rule

Refresh this snapshot and generated database types after every merged database migration. Migrations remain the change history; this file documents the current live state and must not replace migrations.
