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

-- Preserve the immutable movement ledger. Only never-used assets without
-- movements/attachments/references can be permanently deleted.
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
 return new;
end $$;

create or replace function public.su_delete_unused_asset(target_asset_id uuid, confirmation_code text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype;
begin
  if not public.can_su_admin_assets() then raise exception 'SU asset administration required'; end if;
  select * into a from public.assets where id=target_asset_id for update;
  if not found then raise exception 'Asset not found'; end if;
  if confirmation_code is distinct from a.asset_code then raise exception 'Asset code confirmation does not match'; end if;
  if exists(select 1 from public.asset_movements where asset_id=a.id)
     or exists(select 1 from public.asset_assignment_items where asset_id=a.id)
     or exists(select 1 from public.asset_attachments where asset_id=a.id)
     or exists(select 1 from public.asset_maintenance_orders where asset_id=a.id) then
    raise exception 'Asset has history or references. Archive it instead';
  end if;
  perform set_config('app.su_asset_delete','allowed',true);
  delete from public.assets where id=a.id;
  perform set_config('app.su_asset_delete','',true);
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.su_delete_unused_asset(uuid,text) from public,anon;
grant execute on function public.su_delete_unused_asset(uuid,text) to authenticated;
