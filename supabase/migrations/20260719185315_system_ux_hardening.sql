-- System UX hardening: custody token lifecycle, safe employee inactivation,
-- and global currency settings. Additive and data-preserving.

alter table public.asset_assignments
  add column if not exists confirmation_sent_at timestamptz,
  add column if not exists confirmation_opened_at timestamptz,
  add column if not exists confirmation_resend_count integer not null default 0,
  add column if not exists confirmation_invalidated_at timestamptz,
  add column if not exists confirmation_invalidation_reason text;

alter table public.asset_return_events
  alter column confirmation_token_hash drop not null,
  alter column confirmation_expires_at drop not null,
  add column if not exists confirmation_sent_at timestamptz,
  add column if not exists confirmation_opened_at timestamptz,
  add column if not exists confirmation_resend_count integer not null default 0,
  add column if not exists confirmation_invalidated_at timestamptz,
  add column if not exists confirmation_invalidation_reason text;

alter table public.asset_assignments drop constraint if exists asset_assignments_confirmation_link_consistency;
alter table public.asset_assignments add constraint asset_assignments_confirmation_link_consistency check (
  confirmation_token_hash is not null
  or status <> 'pending_receiver_confirmation'
  or confirmation_method = 'admin_override'
);

alter table public.asset_return_events drop constraint if exists asset_return_events_confirmation_link_consistency;
alter table public.asset_return_events add constraint asset_return_events_confirmation_link_consistency check (
  confirmation_token_hash is not null
  or status <> 'pending_receiver_confirmation'
  or confirmation_method = 'admin_override'
  or override_type = 'forced_return_confirmation'
);

create table if not exists public.system_settings(
  id boolean primary key default true check(id),
  currency_code text not null default 'EGP' check(currency_code ~ '^[A-Z]{3}$'),
  currency_symbol text not null default 'ج.م' check(btrim(currency_symbol) <> ''),
  currency_locale text not null default 'ar-EG' check(btrim(currency_locale) <> ''),
  decimal_places integer not null default 2 check(decimal_places between 0 and 4),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
insert into public.system_settings(id) values(true) on conflict(id) do nothing;
alter table public.system_settings enable row level security;
revoke all on table public.system_settings from anon, authenticated;

create or replace function public.get_system_settings()
returns jsonb language sql stable security definer set search_path=public,pg_temp as $$
  select to_jsonb(s) - 'updated_by' from public.system_settings s where id=true
$$;
revoke all on function public.get_system_settings() from public;
grant execute on function public.get_system_settings() to authenticated;

create or replace function public.save_system_settings(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.system_settings%rowtype;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='owner' and status='active') then
    raise exception 'Owner authorization required' using errcode='42501';
  end if;
  update public.system_settings set
    currency_code=upper(coalesce(nullif(btrim(payload->>'currency_code'),''),currency_code)),
    currency_symbol=coalesce(nullif(btrim(payload->>'currency_symbol'),''),currency_symbol),
    currency_locale=coalesce(nullif(btrim(payload->>'currency_locale'),''),currency_locale),
    decimal_places=coalesce((payload->>'decimal_places')::integer,decimal_places),
    updated_by=actor,updated_at=now()
  where id=true returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('system_settings','true','updated',actor,to_jsonb(saved),jsonb_build_object('source','settings'));
  return to_jsonb(saved)-'updated_by';
end $$;
revoke all on function public.save_system_settings(jsonb) from public;
grant execute on function public.save_system_settings(jsonb) to authenticated;

create or replace function public.deactivate_employee(target_employee uuid, reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); before_row public.employees%rowtype; after_row public.employees%rowtype;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role in ('owner','manager') and status='active') then
    raise exception 'Manager authorization required' using errcode='42501';
  end if;
  select * into before_row from public.employees where id=target_employee for update;
  if before_row.id is null then raise exception 'Employee not found'; end if;
  update public.employees set status='terminated',updated_at=now() where id=target_employee returning * into after_row;
  update public.profiles set status='inactive',updated_at=now()
  where employee_id=target_employee and status='active';
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('employees',target_employee::text,'deactivated',actor,to_jsonb(before_row),to_jsonb(after_row),jsonb_build_object('reason',nullif(btrim(coalesce(reason,'')),'')));
  return jsonb_build_object('ok',true,'employee_id',target_employee,'status',after_row.status);
end $$;
revoke all on function public.deactivate_employee(uuid,text) from public;
grant execute on function public.deactivate_employee(uuid,text) to authenticated;

create or replace function public.renew_asset_confirmation_link(target_id uuid, target_kind text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); secret text:=encode(extensions.gen_random_bytes(24),'hex'); hours integer; ass public.asset_assignments%rowtype; ev public.asset_return_events%rowtype;
begin
  if actor is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if target_kind='issue' then
    if not public.has_permission('assets_issue') then raise exception 'assets_issue permission required' using errcode='42501'; end if;
    select receiver_confirmation_hours into hours from public.asset_settings where id=true;
    select * into ass from public.asset_assignments where id=target_id for update;
    if ass.id is null then return jsonb_build_object('status','not_found'); end if;
    if ass.status<>'pending_receiver_confirmation' then return jsonb_build_object('status',case when ass.confirmed_at is not null then 'already_confirmed' else 'not_pending' end); end if;
    update public.asset_assignments set
      confirmation_token_hash=encode(extensions.digest(secret,'sha256'),'hex'),
      confirmation_expires_at=now()+make_interval(hours=>hours),
      confirmation_sent_at=now(),confirmation_opened_at=null,
      confirmation_used_at=null,confirmation_failed_attempts=0,confirmation_locked_until=null,
      confirmation_invalidated_at=null,confirmation_invalidation_reason=null,
      confirmation_resend_count=confirmation_resend_count+1,updated_at=now(),updated_by=actor
    where id=target_id;
    return jsonb_build_object('status','valid','confirmation_token',target_id::text||'.'||secret,'expires_at',now()+make_interval(hours=>hours),'assignment_code',ass.assignment_code);
  elsif target_kind='return' then
    if not public.has_permission('assets_return') then raise exception 'assets_return permission required' using errcode='42501'; end if;
    select return_confirmation_hours into hours from public.asset_settings where id=true;
    select * into ev from public.asset_return_events where id=target_id for update;
    if ev.id is null then return jsonb_build_object('status','not_found'); end if;
    if ev.status<>'pending_receiver_confirmation' then return jsonb_build_object('status',case when ev.confirmed_at is not null then 'already_confirmed' else 'not_pending' end); end if;
    update public.asset_return_events set
      confirmation_token_hash=encode(extensions.digest(secret,'sha256'),'hex'),
      confirmation_expires_at=now()+make_interval(hours=>hours),
      confirmation_sent_at=now(),confirmation_opened_at=null,
      confirmation_used_at=null,confirmation_failed_attempts=0,confirmation_locked_until=null,
      confirmation_invalidated_at=null,confirmation_invalidation_reason=null,
      confirmation_resend_count=confirmation_resend_count+1
    where id=target_id;
    return jsonb_build_object('status','valid','confirmation_token',target_id::text||'.'||secret,'expires_at',now()+make_interval(hours=>hours));
  end if;
  raise exception 'Unsupported confirmation kind';
end $$;
revoke all on function public.renew_asset_confirmation_link(uuid,text) from public;
grant execute on function public.renew_asset_confirmation_link(uuid,text) to authenticated;

create or replace function public.asset_return_confirmation_preview(target_id uuid, secret text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare event public.asset_return_events%rowtype; assignment public.asset_assignments%rowtype;
begin
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null then return jsonb_build_object('status','not_found'); end if;
  if event.confirmed_at is not null or event.status='confirmed' then return jsonb_build_object('status','already_confirmed'); end if;
  if event.status='cancelled' then return jsonb_build_object('status','cancelled'); end if;
  if event.status<>'pending_receiver_confirmation' then return jsonb_build_object('status','not_pending'); end if;
  if event.confirmation_invalidated_at is not null then return jsonb_build_object('status','replaced','reason',event.confirmation_invalidation_reason); end if;
  if event.confirmation_token_hash is null then return jsonb_build_object('status','pending_without_link'); end if;
  if event.confirmation_used_at is not null then return jsonb_build_object('status','already_used'); end if;
  if event.confirmation_expires_at is null or event.confirmation_expires_at<=now() then return jsonb_build_object('status','expired','expired_at',event.confirmation_expires_at); end if;
  if event.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited','locked_until',event.confirmation_locked_until); end if;
  if event.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then
    update public.asset_return_events set confirmation_failed_attempts=confirmation_failed_attempts+1,
      confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' else null end where id=event.id;
    return jsonb_build_object('status','invalid','attempts_remaining',greatest(4-event.confirmation_failed_attempts,0));
  end if;
  update public.asset_return_events set confirmation_opened_at=coalesce(confirmation_opened_at,now()) where id=event.id;
  select * into assignment from public.asset_assignments where id=event.assignment_id;
  return jsonb_build_object('status','valid','assignment_code',assignment.assignment_code,
    'receiver_name',public.mask_asset_receiver_name(assignment.receiver_name_snapshot),'receiver_phone',public.mask_asset_phone(assignment.receiver_phone_snapshot),
    'expires_at',event.confirmation_expires_at,'confirmation_method','bearer_link','identity_verified',false,
    'authenticated_confirmation_available',auth.uid() is not null and assignment.receiver_profile_id=auth.uid(),
    'items',(select jsonb_agg(jsonb_build_object('name',asset.name,'quantity',return_item.quantity,'unit',asset.unit,'condition',return_item.condition_at_return))
      from public.asset_return_items return_item join public.asset_assignment_items item on item.id=return_item.assignment_item_id
      join public.assets asset on asset.id=item.asset_id where return_item.return_event_id=event.id));
end $$;

create or replace function public.asset_confirmation_preview(target_id uuid, secret text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare assignment public.asset_assignments%rowtype;
begin
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null then return jsonb_build_object('status','not_found'); end if;
  if assignment.confirmed_at is not null or assignment.status='issued' then return jsonb_build_object('status','already_confirmed'); end if;
  if assignment.status='cancelled' then return jsonb_build_object('status','cancelled'); end if;
  if assignment.status<>'pending_receiver_confirmation' then return jsonb_build_object('status','not_pending'); end if;
  if assignment.confirmation_invalidated_at is not null then return jsonb_build_object('status','replaced','reason',assignment.confirmation_invalidation_reason); end if;
  if assignment.confirmation_token_hash is null then return jsonb_build_object('status','pending_without_link'); end if;
  if assignment.confirmation_used_at is not null then return jsonb_build_object('status','already_used'); end if;
  if assignment.confirmation_expires_at is null or assignment.confirmation_expires_at<=now() then return jsonb_build_object('status','expired','expired_at',assignment.confirmation_expires_at); end if;
  if assignment.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited','locked_until',assignment.confirmation_locked_until); end if;
  if assignment.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then
    update public.asset_assignments set confirmation_failed_attempts=confirmation_failed_attempts+1,
      confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' else null end where id=assignment.id;
    return jsonb_build_object('status','invalid','attempts_remaining',greatest(4-assignment.confirmation_failed_attempts,0));
  end if;
  update public.asset_assignments set confirmation_opened_at=coalesce(confirmation_opened_at,now()) where id=assignment.id;
  return jsonb_build_object('status','valid','assignment_code',assignment.assignment_code,
    'receiver_name',public.mask_asset_receiver_name(assignment.receiver_name_snapshot),'receiver_phone',public.mask_asset_phone(assignment.receiver_phone_snapshot),
    'expires_at',assignment.confirmation_expires_at,'confirmation_method','bearer_link','identity_verified',false,
    'authenticated_confirmation_available',auth.uid() is not null and assignment.receiver_profile_id=auth.uid(),
    'items',(select jsonb_agg(jsonb_build_object('name',asset.name,'quantity',item.quantity,'unit',asset.unit))
      from public.asset_assignment_items item join public.assets asset on asset.id=item.asset_id where item.assignment_id=assignment.id));
end $$;

-- The public preview and confirmation endpoints intentionally remain callable through their
-- existing grants. Internal mutation functions and tables remain protected by RLS/revokes.
