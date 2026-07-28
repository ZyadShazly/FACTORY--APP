-- Employee lifecycle completion.
-- Adds exact dependency evidence to the existing checked-delete workflow without
-- deleting, rewriting, or changing the meaning of any historical employee data.
begin;

create index if not exists work_schedules_employee_id_idx
  on public.work_schedules(employee_id)
  where employee_id is not null;

create index if not exists holiday_scopes_employee_id_idx
  on public.holiday_scopes(employee_id)
  where employee_id is not null;

create or replace function public.employee_dependency_summary(target_employee_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  payroll_records jsonb;
  profile_records jsonb;
  assignment_records jsonb;
  schedule_records jsonb;
  holiday_records jsonb;
  project_member_records jsonb;
  milestone_records jsonb;
  production_records jsonb;
  dependency_total integer;
begin
  if public.current_identity_role() not in ('owner', 'manager', 'accountant') then
    raise exception 'غير مصرح بعرض بيانات الموظف' using errcode = '42501';
  end if;

  if not exists (select 1 from public.employees where id = target_employee_id) then
    return jsonb_build_object('ok', false, 'error', 'الموظف غير موجود');
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'reference', p.payroll_month,
        'status', p.status,
        'advance_amount', p.advances,
        'label', format(
          'مسير %s · الحالة %s · السلفة %s',
          to_char(p.payroll_month, 'YYYY-MM'),
          p.status,
          p.advances
        )
      )
      order by p.payroll_month desc, p.id
    ),
    '[]'::jsonb
  )
  into payroll_records
  from public.payroll p
  where p.employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'role', p.role,
        'status', p.status,
        'label', format('حساب دخول %s · %s', p.id, coalesce(p.role, 'بدون دور'))
      )
      order by p.id
    ),
    '[]'::jsonb
  )
  into profile_records
  from public.profiles p
  where p.employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'reference', a.assignment_code,
        'status', a.status,
        'project_id', a.project_id,
        'label', format('%s · الحالة %s', a.assignment_code, a.status)
      )
      order by a.created_at desc, a.id
    ),
    '[]'::jsonb
  )
  into assignment_records
  from public.asset_assignments a
  where a.receiver_employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'reference', s.name,
        'status', s.status,
        'effective_from', s.effective_from,
        'effective_to', s.effective_to,
        'label', format(
          '%s · %s إلى %s · %s',
          s.name,
          s.effective_from,
          coalesce(s.effective_to::text, 'مفتوح'),
          s.status
        )
      )
      order by s.effective_from desc, s.id
    ),
    '[]'::jsonb
  )
  into schedule_records
  from public.work_schedules s
  where s.employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', hs.id,
        'reference', hc.name,
        'status', hs.calendar_status,
        'start_date', hs.start_date,
        'end_date', hs.end_date,
        'label', format(
          '%s · %s إلى %s · %s',
          hc.name,
          hs.start_date,
          hs.end_date,
          hs.calendar_status
        )
      )
      order by hs.start_date desc, hs.id
    ),
    '[]'::jsonb
  )
  into holiday_records
  from public.holiday_scopes hs
  join public.holiday_calendar hc on hc.id = hs.holiday_revision_id
  where hs.employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', pm.id,
        'project_id', pm.project_id,
        'reference', p.project_code,
        'status', case when pm.active then 'active' else 'inactive' end,
        'label', format('%s · %s · %s', p.project_code, p.project_name, pm.project_role)
      )
      order by p.project_code, pm.id
    ),
    '[]'::jsonb
  )
  into project_member_records
  from public.project_members pm
  join public.projects p on p.id = pm.project_id
  where pm.employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', m.id,
        'project_id', m.project_id,
        'reference', p.project_code,
        'status', m.status,
        'label', format('%s · %s · مرحلة %s · %s', p.project_code, p.project_name, m.title, m.status)
      )
      order by p.project_code, m.sequence, m.id
    ),
    '[]'::jsonb
  )
  into milestone_records
  from public.project_milestones m
  join public.projects p on p.id = m.project_id
  where m.responsible_employee_id = target_employee_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', operation.id,
        'production_order_id', operation.production_order_id,
        'reference', operation.name,
        'status', operation.status,
        'label', format('%s · %s · أمر %s', operation.name, operation.status, operation.production_order_id)
      )
      order by operation.created_at desc, operation.id
    ),
    '[]'::jsonb
  )
  into production_records
  from public.production_order_operations operation
  where operation.assigned_employee_id = target_employee_id;

  dependency_total :=
    jsonb_array_length(payroll_records)
    + jsonb_array_length(profile_records)
    + jsonb_array_length(assignment_records)
    + jsonb_array_length(schedule_records)
    + jsonb_array_length(holiday_records)
    + jsonb_array_length(project_member_records)
    + jsonb_array_length(milestone_records)
    + jsonb_array_length(production_records);

  return jsonb_build_object(
    'ok', true,
    'can_delete', dependency_total = 0,
    'dependency_total', dependency_total,
    'dependencies', jsonb_build_object(
      'payroll', jsonb_array_length(payroll_records),
      'login_accounts', jsonb_array_length(profile_records),
      'asset_assignments', jsonb_array_length(assignment_records),
      'work_schedules', jsonb_array_length(schedule_records),
      'holiday_scopes', jsonb_array_length(holiday_records),
      'project_memberships', jsonb_array_length(project_member_records),
      'project_milestones', jsonb_array_length(milestone_records),
      'production_operations', jsonb_array_length(production_records)
    ),
    'dependency_records', jsonb_build_object(
      'payroll', payroll_records,
      'login_accounts', profile_records,
      'asset_assignments', assignment_records,
      'work_schedules', schedule_records,
      'holiday_scopes', holiday_records,
      'project_memberships', project_member_records,
      'project_milestones', milestone_records,
      'production_operations', production_records
    ),
    'model_notes', jsonb_build_object(
      'attendance', 'No standalone attendance ledger exists; employee-scoped work schedules and holiday scopes are shown.',
      'advances', 'Advances are stored on payroll rows and shown on each payroll dependency.',
      'external_labor', 'Daily labor has no employee foreign key and is not an employee dependency.'
    )
  );
end;
$$;

revoke all on function public.employee_dependency_summary(uuid) from public, anon;
grant execute on function public.employee_dependency_summary(uuid) to authenticated;

commit;
