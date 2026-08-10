-- Basic audited asset-maintenance workflow.
-- Opens, completes, or cancels a maintenance order while the immutable asset
-- movement ledger keeps availability reversible. No historical rows change.

begin;

create table if not exists public.asset_maintenance_orders (
  id uuid primary key default gen_random_uuid(),
  maintenance_code text not null unique default ('MNT-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  asset_id uuid not null references public.assets(id) on delete restrict,
  maintenance_type text not null check (maintenance_type in ('corrective', 'preventive', 'inspection')),
  status text not null default 'open' check (status in ('open', 'completed', 'cancelled')),
  description text not null check (btrim(description) <> ''),
  service_provider text,
  estimated_cost numeric(14,2) not null default 0 check (estimated_cost >= 0),
  actual_cost numeric(14,2) check (actual_cost >= 0),
  opened_at timestamptz not null default now(),
  expected_completion_date date,
  completed_at timestamptz,
  completion_notes text,
  outcome_status text check (outcome_status in ('working', 'needs_maintenance', 'damaged')),
  cancelled_at timestamptz,
  cancellation_reason text,
  previous_operational_status text not null check (previous_operational_status in ('working', 'needs_maintenance', 'damaged')),
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  completed_by uuid references public.profiles(id) on delete restrict,
  cancelled_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (status = 'open' and completed_at is null and cancelled_at is null)
    or (status = 'completed' and completed_at is not null and completed_by is not null and outcome_status is not null and cancelled_at is null)
    or (status = 'cancelled' and cancelled_at is not null and cancelled_by is not null and btrim(coalesce(cancellation_reason, '')) <> '' and completed_at is null)
  )
);

create unique index if not exists asset_maintenance_one_open_per_asset_idx
  on public.asset_maintenance_orders(asset_id) where status = 'open';
create index if not exists asset_maintenance_status_opened_idx
  on public.asset_maintenance_orders(status, opened_at desc);
create index if not exists asset_maintenance_created_by_idx
  on public.asset_maintenance_orders(created_by);
create index if not exists asset_maintenance_completed_by_idx
  on public.asset_maintenance_orders(completed_by) where completed_by is not null;
create index if not exists asset_maintenance_cancelled_by_idx
  on public.asset_maintenance_orders(cancelled_by) where cancelled_by is not null;

alter table public.asset_maintenance_orders enable row level security;
revoke all on table public.asset_maintenance_orders from anon, authenticated;
grant select on table public.asset_maintenance_orders to authenticated;

drop policy if exists asset_maintenance_read on public.asset_maintenance_orders;
create policy asset_maintenance_read on public.asset_maintenance_orders
for select to authenticated using (public.has_permission('assets_view'));

create or replace function public.protect_asset_integrity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then raise exception 'Assets cannot be deleted; retire them'; end if;
  if new.tracking_mode is distinct from old.tracking_mode and exists(select 1 from public.asset_movements where asset_id = old.id) then
    raise exception 'tracking_mode cannot change after movements exist';
  end if;
  if (new.total_quantity is distinct from old.total_quantity
      or new.available_quantity is distinct from old.available_quantity
      or new.assigned_quantity is distinct from old.assigned_quantity)
    and current_setting('app.asset_balance_update', true) <> 'on' then
    raise exception 'Cached balances may only be changed by ledger movements';
  end if;
  if (new.operational_status = 'under_maintenance' or old.operational_status = 'under_maintenance')
    and new.operational_status is distinct from old.operational_status
    and current_setting('app.asset_maintenance_rpc', true) <> 'on' then
    raise exception 'Maintenance status may only change through the maintenance workflow';
  end if;
  return new;
end
$$;

revoke all on function public.protect_asset_integrity() from public, anon, authenticated;

create or replace function public.open_asset_maintenance(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  asset_row public.assets%rowtype;
  saved public.asset_maintenance_orders%rowtype;
  estimated numeric := coalesce(nullif(payload->>'estimated_cost', '')::numeric, 0);
begin
  if actor is null or not public.has_permission('assets_manage') then
    raise exception 'assets_manage permission required' using errcode = '42501';
  end if;
  if btrim(coalesce(payload->>'description', '')) = '' then raise exception 'Maintenance description is required'; end if;
  if estimated < 0 then raise exception 'Estimated cost cannot be negative'; end if;
  select * into asset_row from public.assets where id = (payload->>'asset_id')::uuid for update;
  if not found then raise exception 'Asset not found'; end if;
  if asset_row.operational_status not in ('working', 'needs_maintenance', 'damaged') then
    raise exception 'Asset is not eligible for maintenance in its current state';
  end if;
  if asset_row.assigned_quantity <> 0 or asset_row.available_quantity <> asset_row.total_quantity then
    raise exception 'Asset must be fully returned and available before maintenance';
  end if;
  if exists(select 1 from public.asset_maintenance_orders where asset_id = asset_row.id and status = 'open') then
    raise exception 'An open maintenance order already exists for this asset';
  end if;

  insert into public.asset_maintenance_orders(
    asset_id, maintenance_type, description, service_provider, estimated_cost,
    expected_completion_date, previous_operational_status, created_by
  ) values (
    asset_row.id, payload->>'maintenance_type', btrim(payload->>'description'),
    nullif(btrim(payload->>'service_provider'), ''), estimated,
    nullif(payload->>'expected_completion_date', '')::date, asset_row.operational_status, actor
  ) returning * into saved;

  insert into public.asset_movements(asset_id, movement_type, quantity, available_delta, reason, metadata, actor_id)
  values(asset_row.id, 'maintenance_started', asset_row.total_quantity, -asset_row.total_quantity,
    saved.description, jsonb_build_object('maintenance_order_id', saved.id, 'maintenance_code', saved.maintenance_code), actor);
  perform set_config('app.asset_maintenance_rpc', 'on', true);
  update public.assets set operational_status = 'under_maintenance', updated_at = now(), updated_by = actor where id = asset_row.id;
  return jsonb_build_object('ok', true, 'maintenance', to_jsonb(saved));
end
$$;

create or replace function public.complete_asset_maintenance(target_id uuid, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.asset_maintenance_orders%rowtype;
  asset_row public.assets%rowtype;
  result_status text := payload->>'outcome_status';
  cost numeric := coalesce(nullif(payload->>'actual_cost', '')::numeric, 0);
begin
  if actor is null or not public.has_permission('assets_manage') then
    raise exception 'assets_manage permission required' using errcode = '42501';
  end if;
  if result_status not in ('working', 'needs_maintenance', 'damaged') then raise exception 'Valid maintenance outcome is required'; end if;
  if cost < 0 then raise exception 'Actual cost cannot be negative'; end if;
  select * into saved from public.asset_maintenance_orders where id = target_id for update;
  if not found then raise exception 'Maintenance order not found'; end if;
  if saved.status <> 'open' then raise exception 'Only an open maintenance order may be completed'; end if;
  select * into asset_row from public.assets where id = saved.asset_id for update;
  if asset_row.operational_status <> 'under_maintenance' or asset_row.available_quantity <> 0 or asset_row.assigned_quantity <> 0 then
    raise exception 'Asset maintenance balance or state is inconsistent';
  end if;
  update public.asset_maintenance_orders set
    status = 'completed', actual_cost = cost, outcome_status = result_status,
    completion_notes = nullif(btrim(payload->>'completion_notes'), ''),
    completed_at = now(), completed_by = actor, updated_at = now()
  where id = target_id returning * into saved;
  insert into public.asset_movements(asset_id, movement_type, quantity, available_delta, reason, metadata, actor_id)
  values(asset_row.id, 'maintenance_completed', asset_row.total_quantity, asset_row.total_quantity,
    coalesce(saved.completion_notes, 'Maintenance completed'),
    jsonb_build_object('maintenance_order_id', saved.id, 'maintenance_code', saved.maintenance_code, 'actual_cost', cost, 'outcome_status', result_status), actor);
  perform set_config('app.asset_maintenance_rpc', 'on', true);
  update public.assets set operational_status = result_status, updated_at = now(), updated_by = actor where id = asset_row.id;
  return jsonb_build_object('ok', true, 'maintenance', to_jsonb(saved));
end
$$;

create or replace function public.cancel_asset_maintenance(target_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.asset_maintenance_orders%rowtype;
  asset_row public.assets%rowtype;
begin
  if actor is null or not public.has_permission('assets_manage') then
    raise exception 'assets_manage permission required' using errcode = '42501';
  end if;
  if btrim(coalesce(reason, '')) = '' then raise exception 'Cancellation reason is required'; end if;
  select * into saved from public.asset_maintenance_orders where id = target_id for update;
  if not found then raise exception 'Maintenance order not found'; end if;
  if saved.status <> 'open' then raise exception 'Only an open maintenance order may be cancelled'; end if;
  select * into asset_row from public.assets where id = saved.asset_id for update;
  if asset_row.operational_status <> 'under_maintenance' or asset_row.available_quantity <> 0 or asset_row.assigned_quantity <> 0 then
    raise exception 'Asset maintenance balance or state is inconsistent';
  end if;
  update public.asset_maintenance_orders set status = 'cancelled', cancellation_reason = btrim(reason),
    cancelled_at = now(), cancelled_by = actor, updated_at = now()
  where id = target_id returning * into saved;
  insert into public.asset_movements(asset_id, movement_type, quantity, available_delta, reason, metadata, actor_id)
  values(asset_row.id, 'reversed', asset_row.total_quantity, asset_row.total_quantity, btrim(reason),
    jsonb_build_object('maintenance_order_id', saved.id, 'maintenance_code', saved.maintenance_code, 'reverses', 'maintenance_started'), actor);
  perform set_config('app.asset_maintenance_rpc', 'on', true);
  update public.assets set operational_status = saved.previous_operational_status, updated_at = now(), updated_by = actor where id = asset_row.id;
  return jsonb_build_object('ok', true, 'maintenance', to_jsonb(saved));
end
$$;

revoke all on function public.open_asset_maintenance(jsonb) from public, anon;
revoke all on function public.complete_asset_maintenance(uuid, jsonb) from public, anon;
revoke all on function public.cancel_asset_maintenance(uuid, text) from public, anon;
grant execute on function public.open_asset_maintenance(jsonb) to authenticated;
grant execute on function public.complete_asset_maintenance(uuid, jsonb) to authenticated;
grant execute on function public.cancel_asset_maintenance(uuid, text) to authenticated;

drop trigger if exists set_updated_at on public.asset_maintenance_orders;
create trigger set_updated_at before update on public.asset_maintenance_orders
for each row execute function public.set_updated_at();
drop trigger if exists audit_changes on public.asset_maintenance_orders;
create trigger audit_changes after insert or update or delete on public.asset_maintenance_orders
for each row execute function public.audit_row_change();

do $$
begin
  alter publication supabase_realtime add table public.asset_maintenance_orders;
exception when duplicate_object then null;
end
$$;

commit;
