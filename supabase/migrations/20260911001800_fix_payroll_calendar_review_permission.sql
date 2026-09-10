-- Pilot blocker: payroll reviewers with payroll_edit could not recalculate payroll
-- because the public calendar resolver is intentionally gated by payroll_calendar_view.
-- Keep the public resolver restricted, and give the protected payroll workflow a
-- private internal resolver instead of broadening calendar visibility.

create or replace function private.resolve_work_calendar_for_payroll(
  target_employee uuid,
  date_from date,
  date_to date,
  as_of_version bigint default null
)
returns table(
  work_date date,
  calendar_version bigint,
  resolved_scope text,
  schedule_id uuid,
  holiday_id uuid,
  holiday_revision_id uuid,
  resolution_reason text,
  required_start_time time,
  required_end_time time,
  required_minutes integer,
  is_paid_holiday boolean,
  is_unpaid_holiday boolean,
  worked_on_holiday_eligible boolean,
  overridden_events jsonb
)
language sql
stable
security definer
set search_path=''
as $$
with args as (
  select coalesce(as_of_version,public.current_payroll_calendar_version()) v
), emp as (
  select e.id,e.department_id
  from public.employees e
  where e.id=target_employee
), days as (
  select d::date work_date
  from generate_series(date_from,date_to,'1 day') d
), base as (
  select days.work_date,s.id schedule_id,s.scope_type,wd.is_working_day,
         wd.required_start_time,wd.required_end_time,wd.required_minutes,
         row_number() over(
           partition by days.work_date
           order by case s.scope_type when 'employee' then 3 when 'department' then 2 else 1 end desc,
                    s.revision_number desc
         ) rn
  from days
  cross join emp
  cross join args
  join public.work_schedules s
    on days.work_date <@ s.effective_period
   and s.valid_from_version<=args.v
   and (s.valid_to_version is null or s.valid_to_version>args.v)
   and (
     s.scope_type='company'
     or s.scope_type='department' and s.department_id=emp.department_id
     or s.scope_type='employee' and s.employee_id=emp.id
   )
  left join public.work_schedule_days wd
    on wd.schedule_id=s.id
   and wd.iso_weekday=extract(isodow from days.work_date)
), events as (
  select days.work_date,h.id revision_id,h.holiday_id,h.holiday_type,h.is_paid,
         h.required_start_time,h.required_end_time,h.required_minutes,sc.scope_type,
         case sc.scope_type when 'employee' then 3 when 'department' then 2 else 1 end priority
  from days
  cross join emp
  cross join args
  join public.holiday_scopes sc
    on days.work_date <@ sc.effective_period
   and sc.valid_from_version<=args.v
   and (sc.valid_to_version is null or sc.valid_to_version>args.v)
   and (
     sc.scope_type='company'
     or sc.scope_type='department' and sc.department_id=emp.department_id
     or sc.scope_type='employee' and sc.employee_id=emp.id
   )
  join public.holiday_calendar h on h.id=sc.holiday_revision_id
), winner as (
  select *,row_number() over(partition by work_date order by priority desc) rn
  from events
), overridden as (
  select work_date,
         jsonb_agg(
           jsonb_build_object(
             'holiday_revision_id',revision_id,
             'holiday_type',holiday_type,
             'scope',scope_type
           ) order by priority desc
         ) filter(where rn>1) items
  from winner
  group by work_date
)
select d.work_date,a.v,w.scope_type,b.schedule_id,w.holiday_id,w.revision_id,
       case
         when w.holiday_type='working_day_override' then 'working_day_override'
         when w.holiday_type='half_day' then 'half_day'
         when w.holiday_type is not null then w.holiday_type
         when coalesce(b.is_working_day,false) then 'scheduled_workday'
         else 'weekly_rest_day'
       end,
       case
         when w.holiday_type in ('half_day','working_day_override') then w.required_start_time
         when w.holiday_type is null then b.required_start_time
       end,
       case
         when w.holiday_type in ('half_day','working_day_override') then w.required_end_time
         when w.holiday_type is null then b.required_end_time
       end,
       case
         when w.holiday_type in ('half_day','working_day_override') then w.required_minutes
         when w.holiday_type is null then coalesce(b.required_minutes,0)
         else 0
       end,
       coalesce(w.is_paid and w.holiday_type not in ('working_day_override'),false),
       coalesce(not w.is_paid and w.holiday_type not in ('working_day_override'),false),
       coalesce(w.holiday_type in ('official_holiday','company_holiday','weekly_off_override'),false),
       coalesce(o.items,'[]'::jsonb)
from days d
cross join args a
left join base b on b.work_date=d.work_date and b.rn=1
left join winner w on w.work_date=d.work_date and w.rn=1
left join overridden o on o.work_date=d.work_date
order by d.work_date
$$;

revoke all on function private.resolve_work_calendar_for_payroll(uuid,date,date,bigint) from public,anon,authenticated;

create or replace function public.update_payroll_review(target_payroll_id uuid, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor_id uuid := auth.uid();
  current_row public.payroll%rowtype;
  updated_row public.payroll%rowtype;
  deduction_value numeric(14,2);
  advance_value numeric(14,2);
  bonus_value numeric(14,2);
  overtime_hours_value numeric(10,2);
  overtime_rate_value numeric(14,2);
  attended_value numeric(6,2);
  absence_value numeric(6,2);
  attendance_source_value text;
  deduction_text text;
  advance_text text;
  bonus_text text;
  schedule_count integer;
  work_days integer;
  work_minutes integer;
  calendar_value bigint;
begin
  if actor_id is null or not public.payroll_review_allowed() then
    raise exception using errcode='42501', message='Payroll review permission required';
  end if;

  select * into current_row from public.payroll where id=target_payroll_id for update;
  if not found then raise exception using errcode='P0002', message='Payroll record was not found'; end if;
  if current_row.status not in ('draft','rejected') then
    raise exception using errcode='23514', message='Only draft or rejected payroll can be recalculated';
  end if;

  deduction_value := greatest(coalesce((payload->>'deductions')::numeric,current_row.deductions),0);
  advance_value := greatest(coalesce((payload->>'advances')::numeric,current_row.advances),0);
  bonus_value := greatest(coalesce((payload->>'bonuses')::numeric,current_row.bonuses),0);
  overtime_hours_value := greatest(coalesce((payload->>'overtime_hours')::numeric,current_row.overtime_hours),0);
  overtime_rate_value := greatest(coalesce((payload->>'overtime_rate')::numeric,current_row.overtime_rate),0);
  attended_value := nullif(payload->>'attended_days','')::numeric;
  absence_value := nullif(payload->>'absence_days','')::numeric;
  attendance_source_value := nullif(btrim(payload->>'attendance_source'),'');
  deduction_text := nullif(btrim(payload->>'deduction_reason'),'');
  advance_text := nullif(btrim(payload->>'advance_reason'),'');
  bonus_text := nullif(btrim(payload->>'bonus_reason'),'');

  if deduction_value>0 and deduction_text is null then raise exception using errcode='23514', message='Deduction reason is required'; end if;
  if advance_value>0 and advance_text is null then raise exception using errcode='23514', message='Advance reason is required'; end if;
  if bonus_value>0 and bonus_text is null then raise exception using errcode='23514', message='Bonus reason is required'; end if;
  if bonus_value is distinct from current_row.bonuses and not public.has_permission('payroll_bonus_manage') then
    raise exception using errcode='42501', message='Payroll bonus permission required';
  end if;
  if attended_value is null then raise exception using errcode='23514', message='Attendance days are required'; end if;
  if absence_value is null then raise exception using errcode='23514', message='Absence days are required'; end if;
  if attended_value<0 or absence_value<0 then raise exception using errcode='23514', message='Attendance values cannot be negative'; end if;
  if attendance_source_value is null then raise exception using errcode='23514', message='Attendance source is required'; end if;

  calendar_value := public.current_payroll_calendar_version();
  select count(*) filter(where c.schedule_id is not null),
         count(*) filter(where c.required_minutes>0),
         coalesce(sum(c.required_minutes),0)
  into schedule_count,work_days,work_minutes
  from private.resolve_work_calendar_for_payroll(
    current_row.employee_id,
    date_trunc('month',current_row.payroll_month)::date,
    (date_trunc('month',current_row.payroll_month)+interval '1 month - 1 day')::date,
    calendar_value
  ) c;

  if schedule_count=0 then raise exception using errcode='23514', message='Approved work calendar is required'; end if;
  if attended_value+absence_value<>work_days then
    raise exception using errcode='23514', message='Attendance and absence must equal scheduled work days';
  end if;

  perform set_config('app.payroll_workflow_rpc','on',true);
  update public.payroll set
    overtime_hours=overtime_hours_value,
    overtime_rate=overtime_rate_value,
    deductions=deduction_value,
    advances=advance_value,
    bonuses=bonus_value,
    deduction_reason=deduction_text,
    advance_reason=advance_text,
    bonus_reason=bonus_text,
    notes=nullif(btrim(payload->>'notes'),''),
    scheduled_work_days=work_days,
    scheduled_minutes=work_minutes,
    attended_days=attended_value,
    absence_days=absence_value,
    attendance_source=attendance_source_value,
    attendance_reviewed_by=actor_id,
    attendance_reviewed_at=now(),
    calendar_version=calendar_value,
    calendar_stale=false,
    calendar_recalculated_by=actor_id,
    calendar_recalculated_at=now(),
    calendar_stale_acknowledged_by=null,
    calendar_stale_acknowledged_at=null,
    status='draft',
    rejection_reason=null,
    rejected_by=null,
    rejected_at=null,
    review_updated_by=actor_id,
    review_updated_at=now()
  where id=target_payroll_id
  returning * into updated_row;

  return jsonb_build_object('ok',true,'payroll',to_jsonb(updated_row));
end
$$;
