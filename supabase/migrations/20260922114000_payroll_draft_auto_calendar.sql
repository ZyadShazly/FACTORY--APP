-- Final V1 payroll usability fix.
-- Populate scheduled work days/minutes at draft creation from the approved payroll calendar.
-- Calendar visibility remains separate; the protected workflow uses the private resolver.

create or replace function public.create_payroll_draft(
  target_employee uuid,
  target_month date,
  payload jsonb,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  employee_row public.employees%rowtype;
  saved public.payroll%rowtype;
  overtime_hours numeric:=coalesce(nullif(payload->>'overtime_hours','')::numeric,0);
  overtime_rate numeric:=coalesce(nullif(payload->>'overtime_rate','')::numeric,0);
  deductions numeric:=coalesce(nullif(payload->>'deductions','')::numeric,0);
  bonuses numeric:=coalesce(nullif(payload->>'bonuses','')::numeric,0);
  advances numeric:=coalesce(nullif(payload->>'advances','')::numeric,0);
  schedule_count integer:=0;
  work_days integer:=null;
  work_minutes integer:=null;
  calendar_value bigint:=null;
begin
  if auth.uid() is null or not public.is_current_profile_active()
     or not (public.current_identity_role() in ('owner','manager') or public.has_permission('payroll_create')) then
    raise exception using errcode='42501',message='Payroll create permission required';
  end if;

  if command_id is null then
    raise exception using errcode='22023',message='Command id is required';
  end if;

  select * into saved
  from public.payroll
  where payroll.command_id=create_payroll_draft.command_id;
  if found then return to_jsonb(saved); end if;

  if target_month is null or date_trunc('month',target_month)::date<>target_month then
    raise exception using errcode='22023',message='Payroll month must be the first day of a month';
  end if;

  if least(overtime_hours,overtime_rate,deductions,bonuses,advances)<0 then
    raise exception using errcode='22023',message='Payroll values cannot be negative';
  end if;
  if deductions>0 and nullif(btrim(payload->>'deduction_reason'),'') is null then
    raise exception using errcode='22023',message='Deduction reason is required';
  end if;
  if advances>0 and nullif(btrim(payload->>'advance_reason'),'') is null then
    raise exception using errcode='22023',message='Advance reason is required';
  end if;
  if bonuses>0 and nullif(btrim(payload->>'bonus_reason'),'') is null then
    raise exception using errcode='22023',message='Bonus reason is required';
  end if;
  if bonuses>0 and not (public.current_identity_role() in ('owner','manager') or public.has_permission('payroll_bonus_manage')) then
    raise exception using errcode='42501',message='Payroll bonus permission required';
  end if;

  select * into employee_row
  from public.employees
  where id=target_employee and status='active'
  for update;
  if not found then
    raise exception using errcode='23503',message='Active employee required';
  end if;

  calendar_value := public.current_payroll_calendar_version();

  select count(*) filter(where c.schedule_id is not null),
         count(*) filter(where c.required_minutes>0),
         coalesce(sum(c.required_minutes),0)
    into schedule_count,work_days,work_minutes
  from private.resolve_work_calendar_for_payroll(
    target_employee,
    target_month,
    (target_month+interval '1 month - 1 day')::date,
    calendar_value
  ) c;

  if schedule_count=0 then
    work_days:=null;
    work_minutes:=null;
    calendar_value:=null;
  end if;

  insert into public.payroll(
    employee_id,payroll_month,base_salary,housing_allowance,transport_allowance,other_allowance,
    overtime_hours,overtime_rate,deductions,deduction_reason,bonuses,bonus_reason,advances,advance_reason,
    notes,status,created_by,command_id,scheduled_work_days,scheduled_minutes,calendar_version,calendar_stale
  )
  values(
    employee_row.id,target_month,coalesce(employee_row.base_salary,0),coalesce(employee_row.housing_allowance,0),
    coalesce(employee_row.transport_allowance,0),coalesce(employee_row.other_allowance,0),
    overtime_hours,overtime_rate,deductions,nullif(btrim(payload->>'deduction_reason'),''),
    bonuses,nullif(btrim(payload->>'bonus_reason'),''),
    advances,nullif(btrim(payload->>'advance_reason'),''),
    nullif(btrim(payload->>'notes'),''),'draft',auth.uid(),command_id,
    work_days,work_minutes,calendar_value,false
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'payroll',saved.id::text,'payroll_draft_created',auth.uid(),to_jsonb(saved),
    jsonb_build_object(
      'salary_source','employee_master_snapshot',
      'calendar_autocalculated',schedule_count>0,
      'calendar_version',calendar_value,
      'scheduled_work_days',work_days,
      'scheduled_minutes',work_minutes
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.create_payroll_draft(uuid,date,jsonb,uuid)
from public,anon,authenticated;
grant execute on function public.create_payroll_draft(uuid,date,jsonb,uuid)
to authenticated;
