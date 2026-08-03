-- Complete covering indexes for the Assets foreign-key graph.
-- Nullable relationships use partial indexes to keep the write/storage cost bounded.
begin;

create index if not exists asset_assignments_confirmed_user_idx
  on public.asset_assignments(confirmed_by_user_id)
  where confirmed_by_user_id is not null;
create index if not exists asset_assignments_created_by_idx
  on public.asset_assignments(created_by);
create index if not exists asset_assignments_department_idx
  on public.asset_assignments(department_id)
  where department_id is not null;
create index if not exists asset_assignments_issue_location_idx
  on public.asset_assignments(issue_location_id)
  where issue_location_id is not null;
create index if not exists asset_assignments_issued_by_idx
  on public.asset_assignments(issued_by)
  where issued_by is not null;
create index if not exists asset_assignments_override_actor_idx
  on public.asset_assignments(override_actor_id)
  where override_actor_id is not null;
create index if not exists asset_assignments_updated_by_idx
  on public.asset_assignments(updated_by);

create index if not exists asset_attachments_return_event_idx
  on public.asset_attachments(return_event_id)
  where return_event_id is not null;
create index if not exists asset_attachments_settlement_idx
  on public.asset_attachments(settlement_id)
  where settlement_id is not null;
create index if not exists asset_attachments_uploaded_by_idx
  on public.asset_attachments(uploaded_by)
  where uploaded_by is not null;

create index if not exists asset_categories_created_by_idx
  on public.asset_categories(created_by)
  where created_by is not null;
create index if not exists asset_categories_updated_by_idx
  on public.asset_categories(updated_by)
  where updated_by is not null;

create index if not exists asset_identity_report_employee_idx
  on public.asset_identity_binding_migration_report(receiver_employee_id);
create index if not exists asset_identity_report_assignment_idx
  on public.asset_identity_binding_migration_report(assignment_id);

create index if not exists asset_locations_created_by_idx
  on public.asset_locations(created_by)
  where created_by is not null;
create index if not exists asset_locations_parent_idx
  on public.asset_locations(parent_id)
  where parent_id is not null;
create index if not exists asset_locations_project_idx
  on public.asset_locations(project_id)
  where project_id is not null;
create index if not exists asset_locations_updated_by_idx
  on public.asset_locations(updated_by)
  where updated_by is not null;

create index if not exists asset_movements_actor_idx
  on public.asset_movements(actor_id)
  where actor_id is not null;
create index if not exists asset_movements_from_location_idx
  on public.asset_movements(from_location_id)
  where from_location_id is not null;
create index if not exists asset_movements_settlement_idx
  on public.asset_movements(settlement_id)
  where settlement_id is not null;
create index if not exists asset_movements_to_location_idx
  on public.asset_movements(to_location_id)
  where to_location_id is not null;

create index if not exists asset_return_events_confirmed_user_idx
  on public.asset_return_events(confirmed_by_user_id)
  where confirmed_by_user_id is not null;
create index if not exists asset_return_events_override_actor_idx
  on public.asset_return_events(override_actor_id)
  where override_actor_id is not null;
create index if not exists asset_return_events_received_by_idx
  on public.asset_return_events(received_by);

create index if not exists asset_settings_updated_by_idx
  on public.asset_settings(updated_by)
  where updated_by is not null;

create index if not exists asset_settlements_approved_by_idx
  on public.asset_settlements(approved_by)
  where approved_by is not null;
create index if not exists asset_settlements_created_by_idx
  on public.asset_settlements(created_by);
create index if not exists asset_settlements_rejected_by_idx
  on public.asset_settlements(rejected_by)
  where rejected_by is not null;

create index if not exists assets_category_idx
  on public.assets(category_id);
create index if not exists assets_created_by_idx
  on public.assets(created_by);
create index if not exists assets_current_location_idx
  on public.assets(current_location_id)
  where current_location_id is not null;
create index if not exists assets_supplier_idx
  on public.assets(supplier_id)
  where supplier_id is not null;
create index if not exists assets_updated_by_idx
  on public.assets(updated_by);

commit;
