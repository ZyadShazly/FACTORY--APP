-- Assets confirmation trust model, Owner emergency controls, and safe Realtime signaling.

alter table public.asset_assignments
  add column if not exists confirmation_method text,
  add column if not exists confirmed_by_user_id uuid references public.profiles(id) on delete restrict,
  add column if not exists override_type text,
  add column if not exists override_actor_id uuid references public.profiles(id) on delete restrict,
  add column if not exists override_at timestamptz,
  add column if not exists override_reason text,
  add column if not exists override_source text;

alter table public.asset_return_events
  add column if not exists confirmation_method text,
  add column if not exists confirmed_by_user_id uuid references public.profiles(id) on delete restrict,
  add column if not exists override_type text,
  add column if not exists override_actor_id uuid references public.profiles(id) on delete restrict,
  add column if not exists override_at timestamptz,
  add column if not exists override_reason text,
  add column if not exists override_source text;

update public.asset_assignments set confirmation_method='bearer_link'
where confirmed_at is not null and confirmation_method is null;
update public.asset_return_events set confirmation_method='bearer_link'
where confirmed_at is not null and confirmation_method is null;

alter table public.asset_assignments drop constraint if exists asset_assignments_confirmation_method_check;
alter table public.asset_assignments add constraint asset_assignments_confirmation_method_check
  check(confirmation_method is null or confirmation_method in ('authenticated_employee','otp','bearer_link','admin_override'));
alter table public.asset_assignments drop constraint if exists asset_assignments_confirmation_identity_check;
alter table public.asset_assignments add constraint asset_assignments_confirmation_identity_check check(
  (confirmed_at is null and confirmation_method is null and confirmed_by_user_id is null)
  or
  (confirmed_at is not null and confirmation_method is not null
    and ((confirmation_method in ('authenticated_employee','admin_override') and confirmed_by_user_id is not null)
      or (confirmation_method in ('otp','bearer_link') and confirmed_by_user_id is null)))
);

alter table public.asset_return_events drop constraint if exists asset_return_events_confirmation_method_check;
alter table public.asset_return_events add constraint asset_return_events_confirmation_method_check
  check(confirmation_method is null or confirmation_method in ('authenticated_employee','otp','bearer_link','admin_override'));
alter table public.asset_return_events drop constraint if exists asset_return_events_confirmation_identity_check;
alter table public.asset_return_events add constraint asset_return_events_confirmation_identity_check check(
  (confirmed_at is null and confirmation_method is null and confirmed_by_user_id is null)
  or
  (confirmed_at is not null and confirmation_method is not null
    and ((confirmation_method in ('authenticated_employee','admin_override') and confirmed_by_user_id is not null)
      or (confirmation_method in ('otp','bearer_link') and confirmed_by_user_id is null)))
);
alter table public.asset_return_events drop constraint if exists asset_return_events_status_check;
alter table public.asset_return_events add constraint asset_return_events_status_check
  check(status in ('pending_receiver_confirmation','confirmed','expired','disputed','cancelled'));

create or replace function public.protect_asset_confirmation_audit() returns trigger
language plpgsql set search_path=public,pg_temp as $$
begin
  if old.confirmed_at is not null and (
    new.confirmed_at is distinct from old.confirmed_at
    or new.confirmation_method is distinct from old.confirmation_method
    or new.confirmed_by_user_id is distinct from old.confirmed_by_user_id
  ) then raise exception 'Confirmation audit fields are immutable'; end if;
  if old.override_at is not null and (
    new.override_at is distinct from old.override_at
    or new.override_type is distinct from old.override_type
    or new.override_actor_id is distinct from old.override_actor_id
    or new.override_reason is distinct from old.override_reason
    or new.override_source is distinct from old.override_source
  ) then raise exception 'Emergency override audit fields are immutable'; end if;
  return new;
end $$;
drop trigger if exists protect_asset_assignment_confirmation_audit on public.asset_assignments;
create trigger protect_asset_assignment_confirmation_audit before update on public.asset_assignments
for each row execute function public.protect_asset_confirmation_audit();
drop trigger if exists protect_asset_return_confirmation_audit on public.asset_return_events;
create trigger protect_asset_return_confirmation_audit before update on public.asset_return_events
for each row execute function public.protect_asset_confirmation_audit();

create or replace function public.apply_asset_assignment_confirmation_internal(target_id uuid, method text, actor uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare assignment public.asset_assignments%rowtype; item record;
begin
  if method not in ('authenticated_employee','bearer_link','admin_override') then raise exception 'Unsupported confirmation method'; end if;
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null or assignment.status<>'pending_receiver_confirmation' then raise exception 'Assignment is not pending confirmation'; end if;
  update public.asset_assignments set status='issued',confirmed_at=now(),confirmation_used_at=now(),confirmation_token_hash=null,
    confirmation_method=method,confirmed_by_user_id=actor,updated_at=now()
  where id=assignment.id;
  for item in select * from public.asset_assignment_items where assignment_id=assignment.id loop
    insert into public.asset_movements(asset_id,movement_type,quantity,assignment_id,reason,metadata)
    values(item.asset_id,'confirmed',item.quantity,assignment.id,'Assignment confirmation',
      jsonb_build_object('confirmation_method',method,'confirmed_by_user_id',actor));
  end loop;
  return jsonb_build_object('status','confirmed','assignment_code',assignment.assignment_code,'confirmation_method',method,'confirmed_by_user_id',actor);
end $$;

create or replace function public.apply_asset_return_confirmation_internal(target_id uuid, method text, actor uuid, emergency_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare event public.asset_return_events%rowtype; returned record; item public.asset_assignment_items%rowtype; assignment public.asset_assignments%rowtype; all_remaining numeric;
begin
  if method not in ('authenticated_employee','bearer_link','admin_override') then raise exception 'Unsupported confirmation method'; end if;
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null or event.status<>'pending_receiver_confirmation' then raise exception 'Return event is not pending confirmation'; end if;
  select * into assignment from public.asset_assignments where id=event.assignment_id for update;
  for returned in
    select return_item.*, assignment_item.asset_id
    from public.asset_return_items return_item
    join public.asset_assignment_items assignment_item on assignment_item.id=return_item.assignment_item_id
    where return_item.return_event_id=event.id
  loop
    select * into item from public.asset_assignment_items where id=returned.assignment_item_id for update;
    if returned.quantity>item.quantity-item.returned_quantity-item.settled_quantity then raise exception 'Return quantity is no longer consistent with assignment balance'; end if;
    update public.asset_assignment_items
      set returned_quantity=returned_quantity+returned.quantity,
          is_active=(returned_quantity+returned.quantity+settled_quantity<quantity)
      where id=item.id;
    insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,return_event_id,reason,metadata)
    values(returned.asset_id,
      case when returned.quantity<item.quantity-item.returned_quantity-item.settled_quantity then 'partially_returned' else 'returned' end,
      returned.quantity,case when returned.condition_at_return='working' then returned.quantity else 0 end,-returned.quantity,
      assignment.id,event.id,'Return confirmation',
      jsonb_build_object('confirmation_method',method,'confirmed_by_user_id',actor,'override_reason',emergency_reason));
    if returned.condition_at_return<>'working' then
      update public.assets set operational_status=returned.condition_at_return,updated_at=now() where id=returned.asset_id;
    end if;
  end loop;
  select coalesce(sum(quantity-returned_quantity-settled_quantity),0) into all_remaining
  from public.asset_assignment_items where assignment_id=assignment.id;
  update public.asset_return_events as current_event set status='confirmed',confirmed_at=now(),confirmation_used_at=now(),confirmation_token_hash=null,
    confirmation_method=method,confirmed_by_user_id=actor,
    received_by=case when method='admin_override' then actor else received_by end,
    override_type=case when method='admin_override' then 'forced_return_confirmation' else override_type end,
    override_actor_id=case when method='admin_override' then actor else override_actor_id end,
    override_at=case when method='admin_override' then now() else override_at end,
    override_reason=case when method='admin_override' then emergency_reason else current_event.override_reason end,
    override_source=case when method='admin_override' then 'admin_override' else override_source end
  where id=event.id;
  update public.asset_assignments set status=case when all_remaining=0 then 'fully_returned' else 'partially_returned' end,updated_at=now()
  where id=assignment.id;
  return jsonb_build_object('status','confirmed','assignment_status',case when all_remaining=0 then 'fully_returned' else 'partially_returned' end,
    'confirmation_method',method,'confirmed_by_user_id',actor);
end $$;

create or replace function public.asset_confirmation_preview(target_id uuid, secret text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare assignment public.asset_assignments%rowtype;
begin
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null or assignment.status<>'pending_receiver_confirmation' or assignment.confirmation_used_at is not null or assignment.confirmation_expires_at<=now() then return jsonb_build_object('status','expired'); end if;
  if assignment.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited'); end if;
  if assignment.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then
    update public.asset_assignments set confirmation_failed_attempts=confirmation_failed_attempts+1,
      confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' else null end where id=assignment.id;
    return jsonb_build_object('status','invalid','attempts_remaining',greatest(4-assignment.confirmation_failed_attempts,0));
  end if;
  return jsonb_build_object('status','valid','assignment_code',assignment.assignment_code,
    'receiver_name',public.mask_asset_receiver_name(assignment.receiver_name_snapshot),'receiver_phone',public.mask_asset_phone(assignment.receiver_phone_snapshot),
    'expires_at',assignment.confirmation_expires_at,'confirmation_method','bearer_link','identity_verified',false,
    'authenticated_confirmation_available',auth.uid() is not null and assignment.receiver_profile_id=auth.uid(),
    'items',(select jsonb_agg(jsonb_build_object('name',asset.name,'quantity',item.quantity,'unit',asset.unit))
      from public.asset_assignment_items item join public.assets asset on asset.id=item.asset_id where item.assignment_id=assignment.id));
end $$;

create or replace function public.asset_return_confirmation_preview(target_id uuid, secret text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare event public.asset_return_events%rowtype; assignment public.asset_assignments%rowtype;
begin
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null or event.status<>'pending_receiver_confirmation' or event.confirmation_used_at is not null or event.confirmation_expires_at<=now() then return jsonb_build_object('status','expired'); end if;
  if event.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited'); end if;
  if event.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then
    update public.asset_return_events set confirmation_failed_attempts=confirmation_failed_attempts+1,
      confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' else null end where id=event.id;
    return jsonb_build_object('status','invalid','attempts_remaining',greatest(4-event.confirmation_failed_attempts,0));
  end if;
  select * into assignment from public.asset_assignments where id=event.assignment_id;
  return jsonb_build_object('status','valid','assignment_code',assignment.assignment_code,
    'receiver_name',public.mask_asset_receiver_name(assignment.receiver_name_snapshot),'receiver_phone',public.mask_asset_phone(assignment.receiver_phone_snapshot),
    'expires_at',event.confirmation_expires_at,'confirmation_method','bearer_link','identity_verified',false,
    'authenticated_confirmation_available',auth.uid() is not null and assignment.receiver_profile_id=auth.uid(),
    'items',(select jsonb_agg(jsonb_build_object('name',asset.name,'quantity',return_item.quantity,'unit',asset.unit,'condition',return_item.condition_at_return))
      from public.asset_return_items return_item join public.asset_assignment_items item on item.id=return_item.assignment_item_id
      join public.assets asset on asset.id=item.asset_id where return_item.return_event_id=event.id));
end $$;

create or replace function public.confirm_asset_assignment(target_id uuid, secret text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare preview jsonb;
begin
  preview:=public.asset_confirmation_preview(target_id,secret);
  if preview->>'status'<>'valid' then return preview; end if;
  return public.apply_asset_assignment_confirmation_internal(target_id,'bearer_link',null);
end $$;

create or replace function public.confirm_asset_assignment_authenticated(target_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); assignment public.asset_assignments%rowtype;
begin
  if actor is null then raise exception 'Authenticated employee confirmation requires a signed-in account' using errcode='42501'; end if;
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null or assignment.status<>'pending_receiver_confirmation' then raise exception 'Assignment is not pending confirmation'; end if;
  if assignment.receiver_profile_id is null or assignment.receiver_profile_id<>actor then raise exception 'Only the linked recipient account may confirm' using errcode='42501'; end if;
  if not exists(select 1 from public.profiles where id=actor and status='active') then raise exception 'Recipient account is not active' using errcode='42501'; end if;
  return public.apply_asset_assignment_confirmation_internal(target_id,'authenticated_employee',actor);
end $$;

create or replace function public.confirm_asset_return(target_id uuid, secret text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare preview jsonb;
begin
  preview:=public.asset_return_confirmation_preview(target_id,secret);
  if preview->>'status'<>'valid' then return preview; end if;
  return public.apply_asset_return_confirmation_internal(target_id,'bearer_link',null,null);
end $$;

create or replace function public.confirm_asset_return_authenticated(target_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); event public.asset_return_events%rowtype; assignment public.asset_assignments%rowtype;
begin
  if actor is null then raise exception 'Authenticated employee confirmation requires a signed-in account' using errcode='42501'; end if;
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null or event.status<>'pending_receiver_confirmation' then raise exception 'Return event is not pending confirmation'; end if;
  select * into assignment from public.asset_assignments where id=event.assignment_id;
  if assignment.receiver_profile_id is null or assignment.receiver_profile_id<>actor then raise exception 'Only the linked recipient account may confirm' using errcode='42501'; end if;
  if not exists(select 1 from public.profiles where id=actor and status='active') then raise exception 'Recipient account is not active' using errcode='42501'; end if;
  return public.apply_asset_return_confirmation_internal(target_id,'authenticated_employee',actor,null);
end $$;

create or replace function public.cancel_pending_asset_assignment(target_id uuid, reason text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); assignment public.asset_assignments%rowtype; item record; affected numeric:=0;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='owner' and status='active') then raise exception 'Owner authorization required' using errcode='42501'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Emergency reason is required'; end if;
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null or assignment.status<>'pending_receiver_confirmation' then raise exception 'Only a pending assignment can be cancelled'; end if;
  if exists(select 1 from public.asset_return_events where assignment_id=assignment.id and status not in ('cancelled','expired'))
    or exists(select 1 from public.asset_settlements settlement join public.asset_assignment_items item on item.id=settlement.assignment_item_id where item.assignment_id=assignment.id and settlement.status<>'rejected')
  then raise exception 'Later return or settlement activity prevents cancellation'; end if;
  for item in select * from public.asset_assignment_items where assignment_id=assignment.id and is_active for update loop
    if item.returned_quantity<>0 or item.settled_quantity<>0 then raise exception 'Assignment quantities are no longer reversible'; end if;
    insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,reason,metadata)
    values(item.asset_id,'reversed',item.quantity,item.quantity,-item.quantity,assignment.id,reason,
      jsonb_build_object('source','admin_override','override_type','pending_issue_cancelled','actor_id',actor));
    update public.asset_assignment_items set is_active=false where id=item.id;
    affected:=affected+item.quantity;
  end loop;
  update public.asset_assignments set status='reversed',reversed_at=now(),reversal_reason=btrim(reason),confirmation_token_hash=null,
    override_type='pending_issue_cancelled',override_actor_id=actor,override_at=now(),override_reason=btrim(reason),override_source='admin_override',updated_by=actor,updated_at=now()
  where id=assignment.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('asset_assignments',assignment.id::text,'pending_issue_cancelled',actor,to_jsonb(assignment),
    (select to_jsonb(current_assignment) from public.asset_assignments current_assignment where current_assignment.id=assignment.id),
    jsonb_build_object('source','admin_override','reason',btrim(reason),'affected_quantity',affected));
  return jsonb_build_object('ok',true,'status','reversed','affected_quantity',affected);
end $$;

create or replace function public.force_confirm_asset_return(target_id uuid, reason text, physical_receipt_verified boolean) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); event public.asset_return_events%rowtype; result jsonb; affected numeric;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='owner' and status='active') then raise exception 'Owner authorization required' using errcode='42501'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Emergency reason is required'; end if;
  if physical_receipt_verified is distinct from true then raise exception 'Physical receipt verification is required'; end if;
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null or event.status<>'pending_receiver_confirmation' then raise exception 'Only a pending physical return can be force-confirmed'; end if;
  select coalesce(sum(quantity),0) into affected from public.asset_return_items where return_event_id=event.id;
  result:=public.apply_asset_return_confirmation_internal(target_id,'admin_override',actor,btrim(reason));
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('asset_return_events',event.id::text,'forced_return_confirmation',actor,to_jsonb(event),
    (select to_jsonb(current_event) from public.asset_return_events current_event where current_event.id=event.id),
    jsonb_build_object('source','admin_override','override_type','forced_return_confirmation','reason',btrim(reason),
      'physical_receipt_verified',true,'affected_quantity',affected,'intended_receiver_employee_id',
      (select receiver_employee_id from public.asset_assignments where id=event.assignment_id)));
  return result||jsonb_build_object('ok',true,'affected_quantity',affected);
end $$;

create or replace function public.cancel_pending_asset_return(target_id uuid, reason text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); event public.asset_return_events%rowtype; affected numeric;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='owner' and status='active') then raise exception 'Owner authorization required' using errcode='42501'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Emergency reason is required'; end if;
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null or event.status<>'pending_receiver_confirmation' then raise exception 'Only an unconfirmed pending return can be cancelled'; end if;
  select coalesce(sum(quantity),0) into affected from public.asset_return_items where return_event_id=event.id;
  update public.asset_return_events set status='cancelled',confirmation_token_hash=null,
    override_type='pending_return_cancelled',override_actor_id=actor,override_at=now(),override_reason=btrim(reason),override_source='admin_override'
  where id=event.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('asset_return_events',event.id::text,'pending_return_cancelled',actor,to_jsonb(event),
    (select to_jsonb(current_event) from public.asset_return_events current_event where current_event.id=event.id),
    jsonb_build_object('source','admin_override','reason',btrim(reason),'affected_quantity',affected,'inventory_delta',0));
  return jsonb_build_object('ok',true,'status','cancelled','affected_quantity',affected,'available_quantity_delta',0);
end $$;

create or replace function public.reverse_asset_assignment(target_id uuid, reason text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); assignment public.asset_assignments%rowtype; item record; affected numeric:=0;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='owner' and status='active') then raise exception 'Owner authorization required' using errcode='42501'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Emergency reason is required'; end if;
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null or assignment.status<>'issued' then raise exception 'Only an issued assignment can be reversed'; end if;
  if exists(select 1 from public.asset_assignment_items where assignment_id=assignment.id and (returned_quantity<>0 or settled_quantity<>0))
    or exists(select 1 from public.asset_return_events where assignment_id=assignment.id and status not in ('cancelled','expired'))
    or exists(select 1 from public.asset_settlements settlement join public.asset_assignment_items item on item.id=settlement.assignment_item_id where item.assignment_id=assignment.id and settlement.status<>'rejected')
  then raise exception 'Later returns or settlements make reversal inconsistent'; end if;
  for item in select * from public.asset_assignment_items where assignment_id=assignment.id and is_active for update loop
    insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,reason,metadata)
    values(item.asset_id,'reversed',item.quantity,item.quantity,-item.quantity,assignment.id,btrim(reason),
      jsonb_build_object('source','admin_override','override_type','issued_assignment_reversal','actor_id',actor));
    update public.asset_assignment_items set is_active=false where id=item.id;
    affected:=affected+item.quantity;
  end loop;
  update public.asset_assignments set status='reversed',reversed_at=now(),reversal_reason=btrim(reason),
    override_type='issued_assignment_reversal',override_actor_id=actor,override_at=now(),override_reason=btrim(reason),override_source='admin_override',updated_by=actor,updated_at=now()
  where id=assignment.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('asset_assignments',assignment.id::text,'issued_assignment_reversal',actor,to_jsonb(assignment),
    (select to_jsonb(current_assignment) from public.asset_assignments current_assignment where current_assignment.id=assignment.id),
    jsonb_build_object('source','admin_override','reason',btrim(reason),'affected_quantity',affected));
  return jsonb_build_object('ok',true,'status','reversed','affected_quantity',affected);
end $$;

-- public.assets remains private, so this non-sensitive singleton provides a reliable refresh signal.
create table if not exists public.asset_realtime_signal(
  id boolean primary key default true check(id),
  entity_id uuid,
  event_type text not null default 'changed',
  updated_at timestamptz not null default now()
);
insert into public.asset_realtime_signal(id,event_type) values(true,'initialized') on conflict(id) do nothing;
alter table public.asset_realtime_signal enable row level security;
drop policy if exists asset_realtime_signal_read on public.asset_realtime_signal;
create policy asset_realtime_signal_read on public.asset_realtime_signal for select to authenticated
using(public.has_permission('assets_view'));
revoke all on table public.asset_realtime_signal from public,anon;
grant select on table public.asset_realtime_signal to authenticated;

create or replace function public.emit_asset_realtime_signal() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.asset_realtime_signal(id,entity_id,event_type,updated_at)
  values(true,case when tg_op='DELETE' then old.id else new.id end,lower(tg_op),clock_timestamp())
  on conflict(id) do update set entity_id=excluded.entity_id,event_type=excluded.event_type,updated_at=excluded.updated_at;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists emit_asset_realtime_signal on public.assets;
create trigger emit_asset_realtime_signal after insert or update or delete on public.assets
for each row execute function public.emit_asset_realtime_signal();

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'asset_categories','asset_locations','asset_settings','assets','asset_assignments','asset_assignment_items',
    'asset_return_events','asset_return_items','asset_settlements','asset_movements','asset_attachments','asset_realtime_signal'
  ] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=table_name) then
      execute format('alter publication supabase_realtime add table public.%I',table_name);
    end if;
  end loop;
end $$;

revoke all on function public.apply_asset_assignment_confirmation_internal(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.apply_asset_return_confirmation_internal(uuid,text,uuid,text) from public,anon,authenticated;
revoke all on function public.protect_asset_confirmation_audit() from public,anon,authenticated;
revoke all on function public.emit_asset_realtime_signal() from public,anon,authenticated;

revoke all on function public.confirm_asset_assignment_authenticated(uuid) from public,anon;
revoke all on function public.confirm_asset_return_authenticated(uuid) from public,anon;
revoke all on function public.cancel_pending_asset_assignment(uuid,text) from public,anon;
revoke all on function public.force_confirm_asset_return(uuid,text,boolean) from public,anon;
revoke all on function public.cancel_pending_asset_return(uuid,text) from public,anon;
revoke all on function public.reverse_asset_assignment(uuid,text) from public,anon;
grant execute on function public.confirm_asset_assignment_authenticated(uuid) to authenticated;
grant execute on function public.confirm_asset_return_authenticated(uuid) to authenticated;
grant execute on function public.cancel_pending_asset_assignment(uuid,text) to authenticated;
grant execute on function public.force_confirm_asset_return(uuid,text,boolean) to authenticated;
grant execute on function public.cancel_pending_asset_return(uuid,text) to authenticated;
grant execute on function public.reverse_asset_assignment(uuid,text) to authenticated;

comment on column public.asset_assignments.confirmation_method is
 'Trust method: bearer_link is possession of a URL only and is not verified recipient identity.';
comment on column public.asset_return_events.confirmation_method is
 'Trust method: bearer_link is possession of a URL only and is not verified recipient identity.';
