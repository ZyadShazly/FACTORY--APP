-- Employee WhatsApp identity for asset custody.
-- Preserves legacy rows: validation is enforced for new employees and phone changes.

create or replace function public.normalize_employee_phone(value text)
returns text
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select regexp_replace(value, '[^0-9]', '', 'g');
$$;

alter table public.employees
  add column if not exists phone_normalized text
  generated always as (public.normalize_employee_phone(coalesce(phone, ''))) stored;

create unique index if not exists employees_phone_normalized_unique
  on public.employees(phone_normalized)
  where phone_normalized <> '';

create or replace function public.validate_employee_whatsapp_phone()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare normalized text;
begin
  if tg_op = 'INSERT' or new.phone is distinct from old.phone then
    normalized := public.normalize_employee_phone(coalesce(new.phone, ''));
    if length(normalized) < 8 or length(normalized) > 15 then
      raise exception 'رقم واتساب الموظف مطلوب ويجب أن يكون من 8 إلى 15 رقمًا' using errcode = '23514';
    end if;
    new.phone := normalized;
  end if;
  return new;
end;
$$;

drop trigger if exists employees_validate_whatsapp_phone on public.employees;
create trigger employees_validate_whatsapp_phone
before insert or update of phone on public.employees
for each row execute function public.validate_employee_whatsapp_phone();

alter table public.employees
  drop constraint if exists employees_phone_required_for_new_rows;
alter table public.employees
  add constraint employees_phone_required_for_new_rows
  check (length(phone_normalized) between 8 and 15) not valid;

comment on column public.employees.phone_normalized is
  'Digits-only employee WhatsApp number used for custody notifications. Legacy invalid rows remain readable until corrected.';

-- Custody issuance must never create a WhatsApp-ineligible assignment.
create or replace function public.issue_asset_assignment(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare ass public.asset_assignments%rowtype; emp public.employees%rowtype; linked public.profiles%rowtype; item jsonb; a public.assets%rowtype;
  qty numeric; secret text:=encode(extensions.gen_random_bytes(24),'hex'); hours int; supplied_profile_id uuid:=nullif(payload->>'receiver_profile_id','')::uuid;
begin
  if not public.has_permission('assets_issue') then raise exception 'assets_issue permission required'; end if;
  select receiver_confirmation_hours into hours from public.asset_settings where id=true;
  select * into emp from public.employees where id=(payload->>'receiver_employee_id')::uuid;
  if emp.id is null or emp.status<>'active' then raise exception 'Active receiver not found'; end if;
  if length(public.normalize_employee_phone(coalesce(emp.phone,''))) not between 8 and 15 then
    raise exception 'لا يمكن إصدار العهدة قبل تسجيل رقم واتساب صحيح للموظف' using errcode='23514';
  end if;
  if supplied_profile_id is not null then
    select * into linked from public.profiles where id=supplied_profile_id for update;
    if linked.id is null or linked.status<>'active' or linked.employee_id is distinct from emp.id then
      raise exception 'Supplied profile is not actively linked to the selected employee' using errcode='23514';
    end if;
  end if;
  insert into public.asset_assignments(status,receiver_employee_id,receiver_profile_id,receiver_name_snapshot,receiver_phone_snapshot,issued_by,project_id,department_id,issue_location_id,purpose,expected_return_at,issued_at,confirmation_token_hash,confirmation_expires_at,notes,created_by,updated_by)
  values('pending_receiver_confirmation',emp.id,supplied_profile_id,emp.full_name,public.normalize_employee_phone(emp.phone),auth.uid(),nullif(payload->>'project_id','')::uuid,nullif(payload->>'department_id','')::uuid,nullif(payload->>'issue_location_id','')::uuid,btrim(payload->>'purpose'),nullif(payload->>'expected_return_at','')::timestamptz,now(),encode(extensions.digest(secret,'sha256'),'hex'),now()+make_interval(hours=>hours),payload->>'notes',auth.uid(),auth.uid()) returning * into ass;
  for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    qty:=(item->>'quantity')::numeric; select * into a from public.assets where id=(item->>'asset_id')::uuid for update;
    if a.id is null or a.operational_status<>'working' then raise exception 'Only working assets can be issued'; end if;
    if a.tracking_mode='serialized' and qty<>1 then raise exception 'Serialized asset quantity must be one'; end if;
    if qty<=0 or a.available_quantity<qty then raise exception 'Requested quantity exceeds available ledger balance'; end if;
    insert into public.asset_assignment_items(assignment_id,asset_id,quantity,is_serialized,condition_at_issue,notes) values(ass.id,a.id,qty,a.tracking_mode='serialized',a.operational_status,item->>'notes');
    insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,from_location_id,to_location_id,reason) values(a.id,'issued',qty,-qty,qty,ass.id,a.current_location_id,ass.issue_location_id,ass.purpose);
  end loop;
  if not exists(select 1 from public.asset_assignment_items where assignment_id=ass.id) then raise exception 'At least one assignment item is required'; end if;
  return jsonb_build_object('ok',true,'assignment_id',ass.id,'assignment_code',ass.assignment_code,'receiver_phone',ass.receiver_phone_snapshot,'confirmation_token',ass.id::text||'.'||secret,'expires_at',ass.confirmation_expires_at,
    'confirmation_mode',case when supplied_profile_id is null then 'bearer_link' else 'authenticated_employee' end);
end
$$;

revoke all on function public.normalize_employee_phone(text) from public;
grant execute on function public.normalize_employee_phone(text) to authenticated;
