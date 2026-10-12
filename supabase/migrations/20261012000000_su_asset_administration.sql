-- SU-only asset administration. No existing asset is modified by this migration.
-- Authorization is checked on the server using the authenticated profile.
create or replace function public.can_su_admin_assets()
returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid())
      and lower(p.email) = 'su@nextep.local'
      and p.role = 'owner'
      and p.status = 'active'
  );
$$;
revoke all on function public.can_su_admin_assets() from public, anon;
grant execute on function public.can_su_admin_assets() to authenticated;

create or replace function public.su_archive_asset(target_asset_id uuid, reason text, restore boolean default false)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype;
begin
  if not public.can_su_admin_assets() then raise exception 'SU asset administration required'; end if;
  if btrim(coalesce(reason,'')) = '' then raise exception 'Reason required'; end if;
  select * into a from public.assets where id=target_asset_id for update;
  if not found then raise exception 'Asset not found'; end if;
  if restore then
    if a.operational_status <> 'retired' then raise exception 'Asset is not archived'; end if;
    update public.assets set operational_status='working', updated_by=auth.uid(), updated_at=now() where id=a.id;
    insert into public.asset_movements(asset_id,movement_type,quantity,reason,metadata)
      values(a.id,'reversed',0,reason,jsonb_build_object('su_action','restore'));
  else
    if a.operational_status = 'retired' then raise exception 'Already archived'; end if;
    if a.assigned_quantity <> 0 or exists (
      select 1 from public.asset_assignment_items i join public.asset_assignments ass on ass.id=i.assignment_id
      where i.asset_id=a.id and ass.status in ('draft','pending_receiver_confirmation','issued','partially_returned','settlement_pending')
    ) then raise exception 'Return or settle active custody before archiving'; end if;
    update public.assets set operational_status='retired',updated_by=auth.uid(),updated_at=now() where id=a.id;
    insert into public.asset_movements(asset_id,movement_type,quantity,reason,metadata)
      values(a.id,'retired',0,reason,jsonb_build_object('su_action','archive'));
  end if;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.su_archive_asset(uuid,text,boolean) from public,anon;
grant execute on function public.su_archive_asset(uuid,text,boolean) to authenticated;

-- Preserve operational ledger history. Only unused assets with at most their initial
-- creation movement, and no attachments/references, can be permanently deleted.
create or replace function public.protect_asset_integrity() returns trigger language plpgsql
set search_path=public,pg_temp as $$
begin
 if tg_op='DELETE' then
   if current_setting('app.su_asset_delete',true) = 'allowed' and public.can_su_admin_assets() then
     return old;
   end if;
   raise exception 'Assets cannot be deleted; retire them';
 end if;
 if new.tracking_mode is distinct from old.tracking_mode and exists(select 1 from public.asset_movements where asset_id=old.id) then
   raise exception 'tracking_mode cannot change after movements exist';
 end if;
 if (new.total_quantity is distinct from old.total_quantity or new.available_quantity is distinct from old.available_quantity or new.assigned_quantity is distinct from old.assigned_quantity)
    and current_setting('app.asset_balance_update',true)<>'on' then
   raise exception 'Cached balances may only be changed by ledger movements';
 end if;
 if (new.operational_status = 'under_maintenance' or old.operational_status = 'under_maintenance')
    and new.operational_status is distinct from old.operational_status
    and current_setting('app.asset_maintenance_rpc',true)<>'on' then
   raise exception 'Maintenance status may only change through the maintenance workflow';
 end if;
 return new;
end $$;

-- A limited deletion exception for the original creation movement ONLY.
create or replace function public.immutable_asset_ledger() returns trigger language plpgsql
set search_path=public,pg_temp as $$
begin
  if tg_op='DELETE' and current_setting('app.su_asset_delete',true)='allowed'
     and public.can_su_admin_assets() and old.movement_type='created' then
    return old;
  end if;
  raise exception 'Asset movement ledger is immutable';
end $$;

create or replace function public.su_delete_unused_asset(target_asset_id uuid, confirmation_code text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype;
begin
  if not public.can_su_admin_assets() then raise exception 'SU asset administration required'; end if;
  select * into a from public.assets where id=target_asset_id for update;
  if not found then raise exception 'Asset not found'; end if;
  if confirmation_code is distinct from a.asset_code then raise exception 'Asset code confirmation does not match'; end if;
  if exists(select 1 from public.asset_movements where asset_id=a.id and movement_type <> 'created')
     or (select count(*) from public.asset_movements where asset_id=a.id) > 1
     or exists(select 1 from public.asset_assignment_items where asset_id=a.id)
     or exists(select 1 from public.asset_attachments where asset_id=a.id)
     or exists(select 1 from public.asset_maintenance_orders where asset_id=a.id) then
    raise exception 'Asset has history or references. Archive it instead';
  end if;
  perform set_config('app.su_asset_delete','allowed',true);
  delete from public.asset_movements where asset_id=a.id;
  delete from public.assets where id=a.id;
  perform set_config('app.su_asset_delete','',true);
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.su_delete_unused_asset(uuid,text) from public,anon;
grant execute on function public.su_delete_unused_asset(uuid,text) to authenticated;

-- Full SU asset metadata amendment, with explicit before/after and dependent-record checks.
-- Quantity remains ledger-driven, never a direct cache rewrite.
create or replace function public.su_update_asset_details(target_asset_id uuid, payload jsonb, reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype; previous jsonb; next_tracking text; next_serial text; next_qty numeric;
begin
 if not public.can_su_admin_assets() then raise exception 'SU asset administration required'; end if;
 if btrim(coalesce(reason,''))='' then raise exception 'Change reason required'; end if;
 select * into a from public.assets where id=target_asset_id for update;
 if not found then raise exception 'Asset not found'; end if;
 previous:=to_jsonb(a);
 -- Operational states and locations require dedicated audited workflows.
 -- Never silently rewrite them through a metadata editing operation.
 if payload ? 'operational_status'
    and (payload->>'operational_status') is distinct from a.operational_status then
   raise exception 'Operational status requires its dedicated movement workflow';
 end if;
 if payload ? 'current_location_id'
    and nullif(payload->>'current_location_id','')::uuid is distinct from a.current_location_id then
   raise exception 'Location changes require the asset transfer workflow';
 end if;
 next_tracking:=coalesce(nullif(payload->>'tracking_mode',''),a.tracking_mode);
 next_serial:=nullif(btrim(payload->>'serial_number'),'');
 if next_tracking not in ('serialized','quantity') then raise exception 'Invalid tracking mode'; end if;
 if next_tracking='serialized' and (a.total_quantity<>1 or a.assigned_quantity<>0) then
   raise exception 'Individual tracking requires exactly one piece and no active custody';
 end if;
 if next_tracking is distinct from a.tracking_mode then
   if exists(select 1 from public.asset_assignment_items where asset_id=a.id) or
      exists(select 1 from public.asset_maintenance_orders where asset_id=a.id) or
      exists(select 1 from public.asset_movements where asset_id=a.id and movement_type<>'created') then
      raise exception 'Tracking cannot be changed after custody, maintenance or other movements; create replacement records';
   end if;
 end if;
 -- The original integrity trigger rejects tracking changes after any movement. Temporarily
 -- allow only this constrained SU transition; the balances are unchanged.
 perform set_config('app.su_asset_tracking','allowed',true);
 update public.assets set
  asset_code=coalesce(nullif(btrim(payload->>'asset_code'),''),a.asset_code),
  name=coalesce(nullif(btrim(payload->>'name'),''),a.name),
  asset_type=coalesce(nullif(payload->>'asset_type',''),a.asset_type),
  category_id=coalesce(nullif(payload->>'category_id','')::uuid,a.category_id),
  tracking_mode=next_tracking,
  brand=payload->>'brand', model=payload->>'model', serial_number=next_serial,
  qr_value=coalesce(nullif(payload->>'qr_value',''),a.qr_value),
  barcode_value=nullif(payload->>'barcode_value',''),
  unit=coalesce(nullif(btrim(payload->>'unit'),''),a.unit),
  purchase_date=nullif(payload->>'purchase_date','')::date,
  purchase_cost=nullif(payload->>'purchase_cost','')::numeric,
  warranty_until=nullif(payload->>'warranty_until','')::date,
  operational_status=a.operational_status,
  current_location_id=a.current_location_id,
  warehouse=payload->>'warehouse', shelf=payload->>'shelf',
  notes=payload->>'notes',updated_at=now(),updated_by=auth.uid()
 where id=a.id;
 perform set_config('app.su_asset_tracking','',true);
 -- Metadata and stock movement occur in this SAME database transaction.
 next_qty:=coalesce(nullif(payload->>'quantity','')::numeric,a.total_quantity);
 if next_qty<0 then raise exception 'Quantity cannot be negative'; end if;
 if next_qty is distinct from a.total_quantity then
   if next_tracking<>'quantity' then raise exception 'Serialized asset quantity cannot be adjusted'; end if;
   perform public.adjust_asset_quantity(a.id,next_qty-a.total_quantity,reason);
 end if;
 return jsonb_build_object('ok',true,'before',previous,'after',(select to_jsonb(t) from public.assets t where t.id=a.id),'reason',reason);
end $$;
revoke all on function public.su_update_asset_details(uuid,jsonb,text) from public,anon;
grant execute on function public.su_update_asset_details(uuid,jsonb,text) to authenticated;

create or replace function public.protect_asset_integrity() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='DELETE' then
   if current_setting('app.su_asset_delete',true)='allowed' and public.can_su_admin_assets() then return old; end if;
   raise exception 'Assets cannot be deleted; retire them';
 end if;
 if new.tracking_mode is distinct from old.tracking_mode and
    not (current_setting('app.su_asset_tracking',true)='allowed' and public.can_su_admin_assets())
    and exists(select 1 from public.asset_movements where asset_id=old.id) then
   raise exception 'tracking_mode cannot change after movements exist';
 end if;
 if (new.total_quantity is distinct from old.total_quantity or new.available_quantity is distinct from old.available_quantity or new.assigned_quantity is distinct from old.assigned_quantity)
    and current_setting('app.asset_balance_update',true)<>'on' then
   raise exception 'Cached balances may only be changed by ledger movements';
 end if;
 if (new.operational_status = 'under_maintenance' or old.operational_status = 'under_maintenance')
    and new.operational_status is distinct from old.operational_status
    and current_setting('app.asset_maintenance_rpc',true)<>'on' then
   raise exception 'Maintenance status may only change through the maintenance workflow';
 end if;
 return new;
end $$;
