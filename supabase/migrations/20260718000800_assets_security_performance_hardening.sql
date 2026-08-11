-- Assets & Tools: final security and performance hardening.
-- Safe to apply after 202607180003 through 202607180007.

-- Pin function lookup so caller-controlled schemas cannot shadow referenced names.
alter function public.asset_refresh_availability(public.assets)
  set search_path = public, pg_temp;
alter function public.apply_asset_movement_balance()
  set search_path = public, pg_temp;
alter function public.protect_asset_integrity()
  set search_path = public, pg_temp;
alter function public.immutable_asset_ledger()
  set search_path = public, pg_temp;
alter function public.protect_assignment_state()
  set search_path = public, pg_temp;
alter function public.mask_asset_receiver_name(text)
  set search_path = public, pg_temp;
alter function public.mask_asset_phone(text)
  set search_path = public, pg_temp;
alter function public.protect_asset_confirmation_audit()
  set search_path = public, pg_temp;
alter function public.apply_asset_assignment_confirmation_internal(uuid, text, uuid)
  set search_path = public, pg_temp;
alter function public.apply_asset_return_confirmation_internal(uuid, text, uuid, text)
  set search_path = public, pg_temp;
alter function public.emit_asset_realtime_signal()
  set search_path = public, pg_temp;
alter function public.validate_asset_assignment_identity_binding()
  set search_path = public, pg_temp;
alter function public.protect_profile_employee_identity_link()
  set search_path = public, pg_temp;

-- Trigger execution does not require callers to have EXECUTE on the trigger
-- function. These helpers are implementation details, not PostgREST RPCs.
revoke execute on function public.asset_refresh_availability(public.assets)
  from public, anon, authenticated;
revoke execute on function public.apply_asset_movement_balance()
  from public, anon, authenticated;
revoke execute on function public.protect_asset_integrity()
  from public, anon, authenticated;
revoke execute on function public.immutable_asset_ledger()
  from public, anon, authenticated;
revoke execute on function public.protect_assignment_state()
  from public, anon, authenticated;
revoke execute on function public.mask_asset_receiver_name(text)
  from public, anon, authenticated;
revoke execute on function public.mask_asset_phone(text)
  from public, anon, authenticated;
revoke execute on function public.protect_asset_confirmation_audit()
  from public, anon, authenticated;
revoke execute on function public.apply_asset_assignment_confirmation_internal(uuid, text, uuid)
  from public, anon, authenticated;
revoke execute on function public.apply_asset_return_confirmation_internal(uuid, text, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.emit_asset_realtime_signal()
  from public, anon, authenticated;
revoke execute on function public.validate_asset_assignment_identity_binding()
  from public, anon, authenticated;
revoke execute on function public.protect_profile_employee_identity_link()
  from public, anon, authenticated;

-- Foreign-key lookup indexes used by assignment, return, settlement, movement,
-- attachment, and realtime refresh paths. IF NOT EXISTS keeps re-application safe.
create index if not exists idx_asset_assignments_receiver_employee_id
  on public.asset_assignments(receiver_employee_id);
create index if not exists idx_asset_assignments_receiver_profile_id
  on public.asset_assignments(receiver_profile_id);
create index if not exists idx_asset_assignments_project_id
  on public.asset_assignments(project_id);
create index if not exists idx_asset_return_events_assignment_id
  on public.asset_return_events(assignment_id);
create index if not exists idx_asset_return_items_assignment_item_id
  on public.asset_return_items(assignment_item_id);
create index if not exists idx_asset_settlements_assignment_item_id
  on public.asset_settlements(assignment_item_id);
create index if not exists idx_asset_movements_asset_id
  on public.asset_movements(asset_id);
create index if not exists idx_asset_movements_assignment_id
  on public.asset_movements(assignment_id);
create index if not exists idx_asset_movements_return_event_id
  on public.asset_movements(return_event_id);
create index if not exists idx_asset_attachments_asset_id
  on public.asset_attachments(asset_id);
create index if not exists idx_asset_attachments_assignment_id
  on public.asset_attachments(assignment_id);

-- Fail closed if an inherited PUBLIC grant or an explicit role grant survives.
do $$
declare
  function_oid oid;
begin
  foreach function_oid in array array[
    'public.asset_refresh_availability(public.assets)'::regprocedure::oid,
    'public.apply_asset_movement_balance()'::regprocedure::oid,
    'public.protect_asset_integrity()'::regprocedure::oid,
    'public.immutable_asset_ledger()'::regprocedure::oid,
    'public.protect_assignment_state()'::regprocedure::oid,
    'public.mask_asset_receiver_name(text)'::regprocedure::oid,
    'public.mask_asset_phone(text)'::regprocedure::oid,
    'public.protect_asset_confirmation_audit()'::regprocedure::oid,
    'public.apply_asset_assignment_confirmation_internal(uuid,text,uuid)'::regprocedure::oid,
    'public.apply_asset_return_confirmation_internal(uuid,text,uuid,text)'::regprocedure::oid,
    'public.emit_asset_realtime_signal()'::regprocedure::oid,
    'public.validate_asset_assignment_identity_binding()'::regprocedure::oid,
    'public.protect_profile_employee_identity_link()'::regprocedure::oid
  ]
  loop
    if has_function_privilege('anon', function_oid, 'EXECUTE')
      or has_function_privilege('authenticated', function_oid, 'EXECUTE') then
      raise exception 'Internal Assets function % remains executable through an API role', function_oid::regprocedure;
    end if;
  end loop;
end
$$;

-- Accepted Advisor design exceptions (intentional, do not "fix"):
-- 1. public.assets keeps RLS enabled with no direct policies; reads use safe RPCs.
-- 2. public.asset_alerts remains an owner-executed security-barrier view with
--    has_permission('assets_view') and its safe six-column projection.
-- 3. External bearer-link preview/confirmation RPCs remain executable by anon;
--    token hashing, expiry, rate limiting, and identity_verified=false are required.
