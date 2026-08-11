-- Canonical employee/profile identity binding for authenticated asset confirmations.
-- Safe both after a fresh 006 application and as recovery for environments that already applied 006.

alter table public.profiles
  add column if not exists employee_id uuid unique references public.employees(id) on delete set null;
create unique index if not exists profiles_employee_id_unique
  on public.profiles(employee_id) where employee_id is not null;

comment on column public.profiles.employee_id is
  'Canonical identity link. Never infer this relationship from names, email addresses, or phone numbers.';

create table if not exists public.asset_identity_binding_migration_report (
  id bigint generated always as identity primary key,
  entity_type text not null check (entity_type in ('assignment','return_event')),
  record_id uuid not null,
  assignment_id uuid not null references public.asset_assignments(id) on delete restrict,
  receiver_employee_id uuid not null references public.employees(id) on delete restrict,
  old_receiver_profile_id uuid,
  old_confirmation_method text,
  action_taken text not null default 'invalid_link_neutralized',
  detected_at timestamptz not null default now(),
  unique(entity_type,record_id)
);

alter table public.asset_identity_binding_migration_report enable row level security;
drop policy if exists asset_identity_binding_report_owner_read on public.asset_identity_binding_migration_report;
create policy asset_identity_binding_report_owner_read
on public.asset_identity_binding_migration_report for select to authenticated
using(public.current_identity_role()='owner');
revoke all on table public.asset_identity_binding_migration_report from public,anon,authenticated;
grant select on table public.asset_identity_binding_migration_report to authenticated;

-- No identity is guessed. Every pre-existing non-canonical link is recorded before it is neutralized.
insert into public.asset_identity_binding_migration_report(
  entity_type,record_id,assignment_id,receiver_employee_id,old_receiver_profile_id,old_confirmation_method
)
select 'assignment',assignment.id,assignment.id,assignment.receiver_employee_id,
  assignment.receiver_profile_id,assignment.confirmation_method
from public.asset_assignments assignment
where assignment.receiver_profile_id is not null
  and not exists(
    select 1 from public.profiles profile
    where profile.id=assignment.receiver_profile_id
      and profile.employee_id=assignment.receiver_employee_id
  )
on conflict(entity_type,record_id) do nothing;

insert into public.asset_identity_binding_migration_report(
  entity_type,record_id,assignment_id,receiver_employee_id,old_receiver_profile_id,old_confirmation_method
)
select 'return_event',event.id,assignment.id,assignment.receiver_employee_id,
  assignment.receiver_profile_id,event.confirmation_method
from public.asset_return_events event
join public.asset_assignments assignment on assignment.id=event.assignment_id
where assignment.receiver_profile_id is not null
  and not exists(
    select 1 from public.profiles profile
    where profile.id=assignment.receiver_profile_id
      and profile.employee_id=assignment.receiver_employee_id
  )
on conflict(entity_type,record_id) do nothing;

-- 006 makes confirmation trust fields immutable. Temporarily replace its audit trigger only
-- for this documented migration repair, then restore it before exposing any new API.
drop trigger if exists protect_asset_assignment_confirmation_audit on public.asset_assignments;
drop trigger if exists protect_asset_return_confirmation_audit on public.asset_return_events;

update public.asset_return_events event
set confirmation_method=case when event.confirmation_method='authenticated_employee' then 'bearer_link' else event.confirmation_method end,
    confirmed_by_user_id=case when event.confirmation_method='authenticated_employee' then null else event.confirmed_by_user_id end
where exists(
  select 1 from public.asset_identity_binding_migration_report report
  where report.entity_type='return_event' and report.record_id=event.id
);

update public.asset_assignments assignment
set receiver_profile_id=null,
    confirmation_method=case when assignment.confirmation_method='authenticated_employee' then 'bearer_link' else assignment.confirmation_method end,
    confirmed_by_user_id=case when assignment.confirmation_method='authenticated_employee' then null else assignment.confirmed_by_user_id end,
    updated_at=now()
where exists(
  select 1 from public.asset_identity_binding_migration_report report
  where report.entity_type='assignment' and report.record_id=assignment.id
);

create trigger protect_asset_assignment_confirmation_audit before update on public.asset_assignments
for each row execute function public.protect_asset_confirmation_audit();
create trigger protect_asset_return_confirmation_audit before update on public.asset_return_events
for each row execute function public.protect_asset_confirmation_audit();

insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
select case report.entity_type when 'assignment' then 'asset_assignments' else 'asset_return_events' end,
  report.record_id::text,'invalid_identity_link_neutralized',null,
  jsonb_build_object('receiver_employee_id',report.receiver_employee_id,'receiver_profile_id',report.old_receiver_profile_id,
    'confirmation_method',report.old_confirmation_method),
  jsonb_build_object('receiver_profile_id',null,'confirmation_method',
    case when report.old_confirmation_method='authenticated_employee' then 'bearer_link' else report.old_confirmation_method end),
  jsonb_build_object('source','migration','migration','202607180007','report_id',report.id)
from public.asset_identity_binding_migration_report report
where report.action_taken='invalid_link_neutralized';

create or replace function public.protect_profile_employee_identity_link() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if tg_op='INSERT' then
    if new.employee_id is not null and auth.role()<>'service_role' then
      raise exception 'Employee identity links must be created through admin_link_profile_employee' using errcode='42501';
    end if;
    return new;
  end if;
  if new.employee_id is distinct from old.employee_id
     and auth.role()<>'service_role'
     and current_setting('app.asset_identity_link_rpc',true)<>'on'
     and not (old.employee_id is not null and new.employee_id is null
       and not exists(select 1 from public.employees where id=old.employee_id)) then
    raise exception 'Employee identity links must be changed through admin_link_profile_employee' using errcode='42501';
  end if;
  return new;
end $$;
revoke all on function public.protect_profile_employee_identity_link() from public,anon,authenticated;
drop trigger if exists protect_profile_employee_identity_link on public.profiles;
create trigger protect_profile_employee_identity_link before insert or update of employee_id on public.profiles
for each row execute function public.protect_profile_employee_identity_link();

create or replace function public.admin_link_profile_employee(target_user_id uuid,target_employee_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); target_profile public.profiles%rowtype; employee public.employees%rowtype; previous_employee_id uuid;
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='owner' and status='active') then
    raise exception 'Owner authorization required' using errcode='42501';
  end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Identity link reason is required'; end if;
  lock table public.profiles in share row exclusive mode;
  select * into target_profile from public.profiles where id=target_user_id for update;
  if target_profile.id is null then raise exception 'Profile not found'; end if;
  previous_employee_id:=target_profile.employee_id;
  if target_employee_id is not null then
    select * into employee from public.employees where id=target_employee_id for update;
    if employee.id is null or employee.status<>'active' then raise exception 'Only an active employee can be linked'; end if;
    if exists(select 1 from public.profiles where employee_id=target_employee_id and id<>target_user_id) then
      raise exception 'Employee is already linked to another system account';
    end if;
  end if;
  if exists(
    select 1 from public.asset_assignments assignment
    where assignment.receiver_profile_id=target_user_id
      and (target_employee_id is null or assignment.receiver_employee_id<>target_employee_id)
  ) then raise exception 'Existing asset assignments prevent changing this identity link'; end if;
  perform set_config('app.asset_identity_link_rpc','on',true);
  update public.profiles set employee_id=target_employee_id where id=target_user_id;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('profiles',target_user_id::text,'employee_identity_link_changed',actor,
    jsonb_build_object('employee_id',previous_employee_id),jsonb_build_object('employee_id',target_employee_id),
    jsonb_build_object('reason',btrim(reason),'source','admin_link_profile_employee'));
  return jsonb_build_object('ok',true,'profile_id',target_user_id,'employee_id',target_employee_id);
end $$;
revoke all on function public.admin_link_profile_employee(uuid,uuid,text) from public,anon;
grant execute on function public.admin_link_profile_employee(uuid,uuid,text) to authenticated;

create or replace function public.validate_asset_assignment_identity_binding() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.receiver_profile_id is not null and not exists(
    select 1 from public.profiles profile
    where profile.id=new.receiver_profile_id and profile.employee_id=new.receiver_employee_id and profile.status='active'
  ) then raise exception 'Receiver profile is not actively linked to the selected employee' using errcode='23514'; end if;
  return new;
end $$;
revoke all on function public.validate_asset_assignment_identity_binding() from public,anon,authenticated;
drop trigger if exists validate_asset_assignment_identity_binding on public.asset_assignments;
create trigger validate_asset_assignment_identity_binding
before insert or update of receiver_employee_id,receiver_profile_id on public.asset_assignments
for each row execute function public.validate_asset_assignment_identity_binding();

create or replace function public.issue_asset_assignment(payload jsonb) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare ass public.asset_assignments%rowtype; emp public.employees%rowtype; linked public.profiles%rowtype; item jsonb; a public.assets%rowtype;
  qty numeric; secret text:=encode(extensions.gen_random_bytes(24),'hex'); hours int; supplied_profile_id uuid:=nullif(payload->>'receiver_profile_id','')::uuid;
begin
  if not public.has_permission('assets_issue') then raise exception 'assets_issue permission required'; end if;
  select receiver_confirmation_hours into hours from public.asset_settings where id=true;
  select * into emp from public.employees where id=(payload->>'receiver_employee_id')::uuid;
  if emp.id is null or emp.status<>'active' then raise exception 'Active receiver not found'; end if;
  if supplied_profile_id is not null then
    select * into linked from public.profiles where id=supplied_profile_id for update;
    if linked.id is null or linked.status<>'active' or linked.employee_id is distinct from emp.id then
      raise exception 'Supplied profile is not actively linked to the selected employee' using errcode='23514';
    end if;
  end if;
  insert into public.asset_assignments(status,receiver_employee_id,receiver_profile_id,receiver_name_snapshot,receiver_phone_snapshot,issued_by,project_id,department_id,issue_location_id,purpose,expected_return_at,issued_at,confirmation_token_hash,confirmation_expires_at,notes,created_by,updated_by)
  values('pending_receiver_confirmation',emp.id,supplied_profile_id,emp.full_name,emp.phone,auth.uid(),nullif(payload->>'project_id','')::uuid,nullif(payload->>'department_id','')::uuid,nullif(payload->>'issue_location_id','')::uuid,btrim(payload->>'purpose'),nullif(payload->>'expected_return_at','')::timestamptz,now(),encode(extensions.digest(secret,'sha256'),'hex'),now()+make_interval(hours=>hours),payload->>'notes',auth.uid(),auth.uid()) returning * into ass;
  for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    qty:=(item->>'quantity')::numeric; select * into a from public.assets where id=(item->>'asset_id')::uuid for update;
    if a.id is null or a.operational_status<>'working' then raise exception 'Only working assets can be issued'; end if;
    if a.tracking_mode='serialized' and qty<>1 then raise exception 'Serialized asset quantity must be one'; end if;
    if qty<=0 or a.available_quantity<qty then raise exception 'Requested quantity exceeds available ledger balance'; end if;
    insert into public.asset_assignment_items(assignment_id,asset_id,quantity,is_serialized,condition_at_issue,notes) values(ass.id,a.id,qty,a.tracking_mode='serialized',a.operational_status,item->>'notes');
    insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,from_location_id,to_location_id,reason) values(a.id,'issued',qty,-qty,qty,ass.id,a.current_location_id,ass.issue_location_id,ass.purpose);
  end loop;
  if not exists(select 1 from public.asset_assignment_items where assignment_id=ass.id) then raise exception 'At least one assignment item is required'; end if;
  return jsonb_build_object('ok',true,'assignment_id',ass.id,'assignment_code',ass.assignment_code,'confirmation_token',ass.id::text||'.'||secret,'expires_at',ass.confirmation_expires_at,
    'confirmation_mode',case when supplied_profile_id is null then 'bearer_link' else 'authenticated_employee' end);
end $$;

create or replace function public.confirm_asset_assignment_authenticated(target_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); assignment public.asset_assignments%rowtype; linked public.profiles%rowtype;
begin
  if actor is null then raise exception 'Authenticated employee confirmation requires a signed-in account' using errcode='42501'; end if;
  select * into assignment from public.asset_assignments where id=target_id for update;
  if assignment.id is null or assignment.status<>'pending_receiver_confirmation' then raise exception 'Assignment is not pending confirmation'; end if;
  if assignment.receiver_profile_id is null or assignment.receiver_profile_id<>actor then raise exception 'Only the linked recipient account may confirm' using errcode='42501'; end if;
  select * into linked from public.profiles where id=actor for update;
  if linked.id is null or linked.status<>'active' or linked.employee_id is distinct from assignment.receiver_employee_id then
    raise exception 'Recipient account is inactive, unlinked, or linked to another employee' using errcode='42501';
  end if;
  return public.apply_asset_assignment_confirmation_internal(target_id,'authenticated_employee',actor);
end $$;

create or replace function public.confirm_asset_return_authenticated(target_id uuid) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); event public.asset_return_events%rowtype; assignment public.asset_assignments%rowtype; linked public.profiles%rowtype;
begin
  if actor is null then raise exception 'Authenticated employee confirmation requires a signed-in account' using errcode='42501'; end if;
  select * into event from public.asset_return_events where id=target_id for update;
  if event.id is null or event.status<>'pending_receiver_confirmation' then raise exception 'Return event is not pending confirmation'; end if;
  select * into assignment from public.asset_assignments where id=event.assignment_id for update;
  if assignment.receiver_profile_id is null or assignment.receiver_profile_id<>actor then raise exception 'Only the linked recipient account may confirm' using errcode='42501'; end if;
  select * into linked from public.profiles where id=actor for update;
  if linked.id is null or linked.status<>'active' or linked.employee_id is distinct from assignment.receiver_employee_id then
    raise exception 'Recipient account is inactive, unlinked, or linked to another employee' using errcode='42501';
  end if;
  return public.apply_asset_return_confirmation_internal(target_id,'authenticated_employee',actor,null);
end $$;

-- A linked employee must use the authenticated path. Bearer confirmation remains available only when no account is linked.
create or replace function public.confirm_asset_assignment(target_id uuid,secret text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare preview jsonb; assignment public.asset_assignments%rowtype;
begin
  preview:=public.asset_confirmation_preview(target_id,secret);
  if preview->>'status'<>'valid' then return preview; end if;
  select * into assignment from public.asset_assignments where id=target_id;
  if assignment.receiver_profile_id is not null then return jsonb_build_object('status','authentication_required'); end if;
  return public.apply_asset_assignment_confirmation_internal(target_id,'bearer_link',null);
end $$;

create or replace function public.confirm_asset_return(target_id uuid,secret text) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare preview jsonb; event public.asset_return_events%rowtype; assignment public.asset_assignments%rowtype;
begin
  preview:=public.asset_return_confirmation_preview(target_id,secret);
  if preview->>'status'<>'valid' then return preview; end if;
  select * into event from public.asset_return_events where id=target_id;
  select * into assignment from public.asset_assignments where id=event.assignment_id;
  if assignment.receiver_profile_id is not null then return jsonb_build_object('status','authentication_required'); end if;
  return public.apply_asset_return_confirmation_internal(target_id,'bearer_link',null,null);
end $$;

-- Existing execute grants are retained by CREATE OR REPLACE. Reassert the intended API surface explicitly.
revoke all on function public.issue_asset_assignment(jsonb) from public,anon;
grant execute on function public.issue_asset_assignment(jsonb) to authenticated;
revoke all on function public.confirm_asset_assignment_authenticated(uuid) from public,anon;
revoke all on function public.confirm_asset_return_authenticated(uuid) from public,anon;
grant execute on function public.confirm_asset_assignment_authenticated(uuid) to authenticated;
grant execute on function public.confirm_asset_return_authenticated(uuid) to authenticated;
