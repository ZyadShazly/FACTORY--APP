-- Safe employee management workflow for Pilot.
-- Additive, preserves all existing employee and transaction data.

alter table public.employees
  add column if not exists status_reason text,
  add column if not exists status_changed_at timestamptz,
  add column if not exists status_changed_by uuid references public.profiles(id) on delete set null;

create or replace function public.employee_admin_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.current_identity_role() in ('owner', 'manager')
$$;

revoke all on function public.employee_admin_allowed() from public, anon;
grant execute on function public.employee_admin_allowed() to authenticated;

-- Accountants may review employees for payroll, but employee master-data changes
-- are limited to owner/manager accounts.
drop policy if exists employees_manage on public.employees;
drop policy if exists employees_select on public.employees;
drop policy if exists employees_select_roles on public.employees;
drop policy if exists employees_insert_admin on public.employees;
drop policy if exists employees_update_admin on public.employees;
drop policy if exists employees_delete_admin on public.employees;

create policy employees_select_roles
on public.employees for select to authenticated
using (public.current_identity_role() in ('owner', 'manager', 'accountant'));

create policy employees_insert_admin
on public.employees for insert to authenticated
with check (public.employee_admin_allowed());

create policy employees_update_admin
on public.employees for update to authenticated
using (public.employee_admin_allowed())
with check (public.employee_admin_allowed());

create policy employees_delete_admin
on public.employees for delete to authenticated
using (public.employee_admin_allowed());

create or replace function public.enforce_employee_controlled_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status
     and current_setting('app.employee_admin_rpc', true) is distinct from 'on' then
    raise exception 'غيّر حالة الموظف من زر الإيقاف أو إعادة التفعيل'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE'
     and current_setting('app.employee_admin_rpc', true) is distinct from 'on' then
    raise exception 'الحذف النهائي متاح فقط بعد فحص ارتباطات الموظف'
      using errcode = '42501';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.enforce_employee_controlled_lifecycle() from public, anon, authenticated;

drop trigger if exists enforce_employee_controlled_lifecycle_update on public.employees;
drop trigger if exists enforce_employee_controlled_lifecycle_delete on public.employees;
create trigger enforce_employee_controlled_lifecycle_update
before update of status on public.employees
for each row execute function public.enforce_employee_controlled_lifecycle();
create trigger enforce_employee_controlled_lifecycle_delete
before delete on public.employees
for each row execute function public.enforce_employee_controlled_lifecycle();

create or replace function public.employee_dependency_summary(target_employee_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  employee_row public.employees%rowtype;
  payroll_count integer;
  profile_count integer;
  assignment_count integer;
  schedule_count integer;
  holiday_count integer;
  project_member_count integer;
  milestone_count integer;
  production_count integer;
  dependency_total integer;
begin
  if public.current_identity_role() not in ('owner', 'manager', 'accountant') then
    raise exception 'غير مصرح بعرض بيانات الموظف' using errcode = '42501';
  end if;

  select * into employee_row from public.employees where id = target_employee_id;
  if employee_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'الموظف غير موجود');
  end if;

  select count(*) into payroll_count from public.payroll where employee_id = target_employee_id;
  select count(*) into profile_count from public.profiles where employee_id = target_employee_id;
  select count(*) into assignment_count from public.asset_assignments where receiver_employee_id = target_employee_id;
  select count(*) into schedule_count from public.work_schedules where employee_id = target_employee_id;
  select count(*) into holiday_count from public.holiday_scopes where employee_id = target_employee_id;
  select count(*) into project_member_count from public.project_members where employee_id = target_employee_id;
  select count(*) into milestone_count from public.project_milestones where responsible_employee_id = target_employee_id;
  select count(*) into production_count from public.production_order_operations where assigned_employee_id = target_employee_id;

  dependency_total := payroll_count + profile_count + assignment_count + schedule_count + holiday_count
    + project_member_count + milestone_count + production_count;

  return jsonb_build_object(
    'ok', true,
    'can_delete', dependency_total = 0,
    'dependency_total', dependency_total,
    'dependencies', jsonb_build_object(
      'payroll', payroll_count,
      'login_accounts', profile_count,
      'asset_assignments', assignment_count,
      'work_schedules', schedule_count,
      'holiday_scopes', holiday_count,
      'project_memberships', project_member_count,
      'project_milestones', milestone_count,
      'production_operations', production_count
    )
  );
end;
$$;

revoke all on function public.employee_dependency_summary(uuid) from public, anon;
grant execute on function public.employee_dependency_summary(uuid) to authenticated;

create or replace function public.update_employee_record(target_employee_id uuid, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  old_row public.employees%rowtype;
  updated_row public.employees%rowtype;
  normalized_phone text;
  new_name text := btrim(coalesce(payload->>'full_name', ''));
begin
  if not public.employee_admin_allowed() then
    raise exception 'فقط المالك أو المدير يمكنه تعديل الموظف' using errcode = '42501';
  end if;

  select * into old_row from public.employees where id = target_employee_id for update;
  if old_row.id is null then raise exception 'الموظف غير موجود'; end if;
  if new_name = '' then raise exception 'اسم الموظف مطلوب' using errcode = '23514'; end if;

  normalized_phone := public.normalize_employee_phone(payload->>'phone');
  if normalized_phone is null then
    raise exception 'رقم واتساب مطلوب بصيغة دولية صحيحة' using errcode = '23514';
  end if;

  update public.employees
  set full_name = new_name,
      phone = normalized_phone,
      job_title = nullif(btrim(payload->>'job_title'), ''),
      department = nullif(btrim(payload->>'department'), ''),
      department_id = nullif(payload->>'department_id', '')::uuid,
      base_salary = greatest(coalesce((payload->>'base_salary')::numeric, 0), 0),
      housing_allowance = greatest(coalesce((payload->>'housing_allowance')::numeric, 0), 0),
      transport_allowance = greatest(coalesce((payload->>'transport_allowance')::numeric, 0), 0),
      other_allowance = greatest(coalesce((payload->>'other_allowance')::numeric, 0), 0),
      hire_date = nullif(payload->>'hire_date', '')::date,
      updated_at = now()
  where id = target_employee_id
  returning * into updated_row;

  return jsonb_build_object('ok', true, 'employee', to_jsonb(updated_row));
end;
$$;

revoke all on function public.update_employee_record(uuid, jsonb) from public, anon;
grant execute on function public.update_employee_record(uuid, jsonb) to authenticated;

create or replace function public.set_employee_status(target_employee_id uuid, target_status text, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  employee_row public.employees%rowtype;
  linked_accounts integer;
begin
  if not public.employee_admin_allowed() then
    raise exception 'فقط المالك أو المدير يمكنه تغيير حالة الموظف' using errcode = '42501';
  end if;
  if target_status not in ('active', 'suspended', 'resigned', 'terminated') then
    raise exception 'حالة الموظف غير مدعومة' using errcode = '23514';
  end if;
  if btrim(coalesce(reason, '')) = '' then
    raise exception 'سبب تغيير الحالة مطلوب' using errcode = '23514';
  end if;

  select * into employee_row from public.employees where id = target_employee_id for update;
  if employee_row.id is null then raise exception 'الموظف غير موجود'; end if;
  if employee_row.status = target_status then
    return jsonb_build_object('ok', true, 'unchanged', true, 'employee', to_jsonb(employee_row));
  end if;

  perform set_config('app.employee_admin_rpc', 'on', true);
  update public.employees
  set status = target_status,
      status_reason = btrim(reason),
      status_changed_at = now(),
      status_changed_by = auth.uid(),
      updated_at = now()
  where id = target_employee_id
  returning * into employee_row;

  select count(*) into linked_accounts from public.profiles where employee_id = target_employee_id;

  return jsonb_build_object(
    'ok', true,
    'employee', to_jsonb(employee_row),
    'linked_login_accounts', linked_accounts,
    'login_account_changed', false
  );
end;
$$;

revoke all on function public.set_employee_status(uuid, text, text) from public, anon;
grant execute on function public.set_employee_status(uuid, text, text) to authenticated;

create or replace function public.delete_employee_if_unused(target_employee_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  employee_row public.employees%rowtype;
  summary jsonb;
begin
  if not public.employee_admin_allowed() then
    raise exception 'فقط المالك أو المدير يمكنه حذف سجل تجريبي' using errcode = '42501';
  end if;
  if btrim(coalesce(reason, '')) = '' then
    raise exception 'سبب الحذف مطلوب' using errcode = '23514';
  end if;

  select * into employee_row from public.employees where id = target_employee_id for update;
  if employee_row.id is null then raise exception 'الموظف غير موجود'; end if;

  summary := public.employee_dependency_summary(target_employee_id);
  if not coalesce((summary->>'can_delete')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'error', 'لا يمكن حذف الموظف لأن له حسابًا أو معاملات مرتبطة. استخدم الإيقاف بدلًا من الحذف.',
      'summary', summary
    );
  end if;

  insert into public.audit_log(table_name, record_id, action, actor_id, old_data, metadata)
  values ('employees', target_employee_id::text, 'permanent_delete_requested', auth.uid(), to_jsonb(employee_row), jsonb_build_object('reason', btrim(reason)));

  perform set_config('app.employee_admin_rpc', 'on', true);
  delete from public.employees where id = target_employee_id;

  return jsonb_build_object('ok', true, 'deleted_id', target_employee_id);
end;
$$;

revoke all on function public.delete_employee_if_unused(uuid, text) from public, anon;
grant execute on function public.delete_employee_if_unused(uuid, text) to authenticated;
