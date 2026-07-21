-- Employee WhatsApp identity and asset-custody delivery hardening.
-- Additive and data-preserving: legacy employee rows are not rewritten.

create or replace function public.normalize_employee_phone(input_phone text)
returns text
language plpgsql
immutable
strict
set search_path = public, pg_temp
as $$
declare
  normalized text;
begin
  normalized := regexp_replace(btrim(input_phone), '[^0-9+]', '', 'g');
  if normalized like '00%' then
    normalized := '+' || substr(normalized, 3);
  end if;
  if normalized !~ '^\+[1-9][0-9]{7,14}$' then
    return null;
  end if;
  return normalized;
end;
$$;

revoke all on function public.normalize_employee_phone(text) from public, anon, authenticated;
grant execute on function public.normalize_employee_phone(text) to authenticated;

create or replace function public.validate_employee_whatsapp_phone()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  normalized text;
begin
  if tg_op = 'INSERT' or new.phone is distinct from old.phone then
    normalized := public.normalize_employee_phone(new.phone);
    if normalized is null then
      raise exception 'رقم واتساب الموظف مطلوب بصيغة دولية، مثال: +9665XXXXXXXX أو +201XXXXXXXXX'
        using errcode = '23514';
    end if;
    new.phone := normalized;
    new.updated_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.validate_employee_whatsapp_phone() from public, anon, authenticated;

drop trigger if exists employees_validate_whatsapp_phone on public.employees;
create trigger employees_validate_whatsapp_phone
before insert or update of phone on public.employees
for each row execute function public.validate_employee_whatsapp_phone();

create unique index if not exists employees_phone_normalized_unique
on public.employees (public.normalize_employee_phone(phone))
where public.normalize_employee_phone(phone) is not null;

create or replace function public.issue_asset_assignment(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  ass public.asset_assignments%rowtype;
  emp public.employees%rowtype;
  linked public.profiles%rowtype;
  assignment_item jsonb;
  target_asset public.assets%rowtype;
  qty numeric;
  secret text := encode(extensions.gen_random_bytes(24), 'hex');
  hours int;
  supplied_profile_id uuid := nullif(payload->>'receiver_profile_id', '')::uuid;
  whatsapp_phone text;
begin
  if not public.has_permission('assets_issue') then
    raise exception 'assets_issue permission required';
  end if;

  select receiver_confirmation_hours into hours
  from public.asset_settings
  where id = true;

  select * into emp
  from public.employees
  where id = (payload->>'receiver_employee_id')::uuid;

  if emp.id is null or emp.status <> 'active' then
    raise exception 'Active receiver not found';
  end if;

  whatsapp_phone := public.normalize_employee_phone(emp.phone);
  if whatsapp_phone is null then
    raise exception 'لا يمكن إصدار العهدة: أضف رقم واتساب صالح للموظف بصيغة دولية أولًا'
      using errcode = '23514';
  end if;

  if supplied_profile_id is not null then
    select * into linked
    from public.profiles
    where id = supplied_profile_id
    for update;

    if linked.id is null or linked.status <> 'active' or linked.employee_id is distinct from emp.id then
      raise exception 'Supplied profile is not actively linked to the selected employee'
        using errcode = '23514';
    end if;
  end if;

  insert into public.asset_assignments(
    status, receiver_employee_id, receiver_profile_id,
    receiver_name_snapshot, receiver_phone_snapshot,
    issued_by, project_id, department_id, issue_location_id,
    purpose, expected_return_at, issued_at,
    confirmation_token_hash, confirmation_expires_at,
    notes, created_by, updated_by
  ) values (
    'pending_receiver_confirmation', emp.id, supplied_profile_id,
    emp.full_name, whatsapp_phone,
    auth.uid(), nullif(payload->>'project_id', '')::uuid,
    nullif(payload->>'department_id', '')::uuid,
    nullif(payload->>'issue_location_id', '')::uuid,
    btrim(payload->>'purpose'),
    nullif(payload->>'expected_return_at', '')::timestamptz,
    now(), encode(extensions.digest(secret, 'sha256'), 'hex'),
    now() + make_interval(hours => hours),
    payload->>'notes', auth.uid(), auth.uid()
  ) returning * into ass;

  for assignment_item in
    select * from jsonb_array_elements(coalesce(payload->'items', '[]'::jsonb))
  loop
    qty := (assignment_item->>'quantity')::numeric;
    select * into target_asset
    from public.assets
    where id = (assignment_item->>'asset_id')::uuid
    for update;

    if target_asset.id is null or target_asset.operational_status <> 'working' then
      raise exception 'Only working assets can be issued';
    end if;
    if target_asset.tracking_mode = 'serialized' and qty <> 1 then
      raise exception 'Serialized asset quantity must be one';
    end if;
    if qty <= 0 or target_asset.available_quantity < qty then
      raise exception 'Requested quantity exceeds available ledger balance';
    end if;

    insert into public.asset_assignment_items(
      assignment_id, asset_id, quantity, is_serialized, condition_at_issue, notes
    ) values (
      ass.id, target_asset.id, qty, target_asset.tracking_mode = 'serialized',
      target_asset.operational_status, assignment_item->>'notes'
    );

    insert into public.asset_movements(
      asset_id, movement_type, quantity, available_delta, assigned_delta,
      assignment_id, from_location_id, to_location_id, reason
    ) values (
      target_asset.id, 'issued', qty, -qty, qty, ass.id,
      target_asset.current_location_id, ass.issue_location_id, ass.purpose
    );
  end loop;

  if not exists (
    select 1 from public.asset_assignment_items where assignment_id = ass.id
  ) then
    raise exception 'At least one assignment item is required';
  end if;

  return jsonb_build_object(
    'ok', true,
    'assignment_id', ass.id,
    'assignment_code', ass.assignment_code,
    'receiver_phone', whatsapp_phone,
    'confirmation_token', ass.id::text || '.' || secret,
    'expires_at', ass.confirmation_expires_at,
    'confirmation_mode', case when supplied_profile_id is null then 'bearer_link' else 'authenticated_employee' end
  );
end;
$$;

revoke all on function public.issue_asset_assignment(jsonb) from public, anon;
grant execute on function public.issue_asset_assignment(jsonb) to authenticated;
