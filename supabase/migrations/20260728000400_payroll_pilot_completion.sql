begin;

-- Review evidence only. The existing generated gross/net payroll formula is unchanged.
alter table public.payroll
  add column if not exists scheduled_work_days integer,
  add column if not exists scheduled_minutes integer,
  add column if not exists attended_days numeric(6,2),
  add column if not exists absence_days numeric(6,2),
  add column if not exists attendance_source text,
  add column if not exists attendance_reviewed_by uuid references public.profiles(id) on delete set null,
  add column if not exists attendance_reviewed_at timestamptz;

alter table public.payroll drop constraint if exists payroll_review_evidence_nonnegative;
alter table public.payroll add constraint payroll_review_evidence_nonnegative check (
  (scheduled_work_days is null or scheduled_work_days >= 0)
  and (scheduled_minutes is null or scheduled_minutes >= 0)
  and (attended_days is null or attended_days >= 0)
  and (absence_days is null or absence_days >= 0)
);

create index if not exists payroll_project_id_idx on public.payroll(project_id) where project_id is not null;
create index if not exists payroll_created_by_idx on public.payroll(created_by) where created_by is not null;
create index if not exists payroll_approved_by_idx on public.payroll(approved_by) where approved_by is not null;
create index if not exists payroll_rejected_by_idx on public.payroll(rejected_by) where rejected_by is not null;
create index if not exists payroll_review_updated_by_idx on public.payroll(review_updated_by) where review_updated_by is not null;
create index if not exists payroll_calendar_recalculated_by_idx on public.payroll(calendar_recalculated_by) where calendar_recalculated_by is not null;
create index if not exists payroll_calendar_stale_acknowledged_by_idx on public.payroll(calendar_stale_acknowledged_by) where calendar_stale_acknowledged_by is not null;
create index if not exists payroll_attendance_reviewed_by_idx on public.payroll(attendance_reviewed_by) where attendance_reviewed_by is not null;

create or replace function public.payroll_review_allowed()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.current_identity_role() in ('owner','manager')
    or public.has_permission('payroll_edit')
    or public.has_permission('payroll_approve')
$$;

revoke all on function public.payroll_review_allowed() from public, anon;
grant execute on function public.payroll_review_allowed() to authenticated;

create or replace function private.payroll_review_blockers(target_payroll_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(message order by priority), '[]'::jsonb)
  from (
    select 10 priority, 'تقويم العمل غير مراجع لهذا الشهر' message
      from public.payroll p where p.id=target_payroll_id and (p.scheduled_work_days is null or p.scheduled_minutes is null)
    union all select 20, 'أيام الحضور مطلوبة'
      from public.payroll p where p.id=target_payroll_id and p.attended_days is null
    union all select 30, 'أيام الغياب مطلوبة'
      from public.payroll p where p.id=target_payroll_id and p.absence_days is null
    union all select 40, 'مصدر الحضور والغياب مطلوب'
      from public.payroll p where p.id=target_payroll_id and nullif(btrim(p.attendance_source),'') is null
    union all select 50, 'مجموع الحضور والغياب يجب أن يساوي أيام العمل المجدولة'
      from public.payroll p where p.id=target_payroll_id
        and p.scheduled_work_days is not null and p.attended_days is not null and p.absence_days is not null
        and p.attended_days + p.absence_days <> p.scheduled_work_days
    union all select 60, 'تقويم العمل تغير؛ أعد مراجعة المسير'
      from public.payroll p where p.id=target_payroll_id and p.calendar_stale
    union all select 70, 'سبب الخصم مطلوب قبل الاعتماد'
      from public.payroll p where p.id=target_payroll_id and p.deductions > 0 and nullif(btrim(p.deduction_reason),'') is null
    union all select 80, 'تفاصيل السلفة مطلوبة قبل الاعتماد'
      from public.payroll p where p.id=target_payroll_id and p.advances > 0 and nullif(btrim(p.advance_reason),'') is null
    union all select 90, 'سبب المكافأة مطلوب قبل الاعتماد'
      from public.payroll p where p.id=target_payroll_id and p.bonuses > 0 and nullif(btrim(p.bonus_reason),'') is null
  ) blockers
$$;

revoke all on function private.payroll_review_blockers(uuid) from public, anon, authenticated;

create or replace function public.get_payroll_review_snapshot(target_payroll_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  payroll_row public.payroll%rowtype;
  employee_name text;
  blockers jsonb;
begin
  if actor_id is null or not public.has_permission('payroll_view') then
    raise exception using errcode='42501', message='Payroll view permission required';
  end if;

  select p into payroll_row from public.payroll p where p.id=target_payroll_id;
  if not found then raise exception using errcode='P0002', message='Payroll record was not found'; end if;
  select e.full_name into employee_name from public.employees e where e.id=payroll_row.employee_id;

  blockers := private.payroll_review_blockers(target_payroll_id);
  return jsonb_build_object(
    'ok', true,
    'payroll', to_jsonb(payroll_row) || jsonb_build_object('employee_name', employee_name),
    'review_ready', jsonb_array_length(blockers)=0,
    'blockers', blockers,
    'sources', jsonb_build_object(
      'salary_snapshot', 'نسخة بيانات الموظف المحفوظة في مسير الشهر',
      'work_calendar', 'تقويم العمل المعتمد وإصداره المحفوظ',
      'attendance', coalesce(payroll_row.attendance_source, 'لم يسجل بعد'),
      'review_inputs', 'إدخال المراجع مع سبب إلزامي عند وجود قيمة',
      'formula', 'معادلة صافي الراتب الحالية المحفوظة في قاعدة البيانات'
    )
  );
end
$$;

revoke all on function public.get_payroll_review_snapshot(uuid) from public, anon;
grant execute on function public.get_payroll_review_snapshot(uuid) to authenticated;

create or replace function public.update_payroll_review(target_payroll_id uuid, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
  into schedule_count, work_days, work_minutes
  from public.resolve_work_calendar(
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
    overtime_hours=overtime_hours_value, overtime_rate=overtime_rate_value,
    deductions=deduction_value, advances=advance_value, bonuses=bonus_value,
    deduction_reason=deduction_text, advance_reason=advance_text, bonus_reason=bonus_text,
    notes=nullif(btrim(payload->>'notes'),''),
    scheduled_work_days=work_days, scheduled_minutes=work_minutes,
    attended_days=attended_value, absence_days=absence_value,
    attendance_source=attendance_source_value,
    attendance_reviewed_by=actor_id, attendance_reviewed_at=now(),
    calendar_version=calendar_value, calendar_stale=false,
    calendar_recalculated_by=actor_id, calendar_recalculated_at=now(),
    calendar_stale_acknowledged_by=null, calendar_stale_acknowledged_at=null,
    status='draft', rejection_reason=null, rejected_by=null, rejected_at=null,
    review_updated_by=actor_id, review_updated_at=now()
  where id=target_payroll_id returning * into updated_row;

  return jsonb_build_object('ok',true,'payroll',to_jsonb(updated_row));
end
$$;

revoke all on function public.update_payroll_review(uuid,jsonb) from public, anon;
grant execute on function public.update_payroll_review(uuid,jsonb) to authenticated;

create or replace function public.review_payroll(target_payroll_id uuid, approve boolean, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  current_row public.payroll%rowtype;
  result_row public.payroll%rowtype;
  decision_reason text := nullif(btrim(reason),'');
  blockers jsonb;
begin
  if actor_id is null or not public.has_permission('payroll_approve') then
    raise exception using errcode='42501', message='Payroll approval permission required';
  end if;
  select * into current_row from public.payroll where id=target_payroll_id for update;
  if not found then raise exception using errcode='P0002', message='Payroll record was not found'; end if;
  if current_row.status not in ('draft','rejected') then
    raise exception using errcode='23514', message='Only draft or rejected payroll can be reviewed';
  end if;

  perform set_config('app.payroll_workflow_rpc','on',true);
  if approve then
    blockers := private.payroll_review_blockers(target_payroll_id);
    if jsonb_array_length(blockers)>0 then
      raise exception using errcode='23514', message='Payroll review details are incomplete', detail=blockers::text;
    end if;
    update public.payroll set status='approved',approved_by=actor_id,approved_at=now(),
      rejection_reason=null,rejected_by=null,rejected_at=null
    where id=target_payroll_id returning * into result_row;
  else
    if decision_reason is null then raise exception using errcode='23514', message='Rejection reason is required'; end if;
    update public.payroll set status='rejected',rejection_reason=decision_reason,
      rejected_by=actor_id,rejected_at=now(),approved_by=null,approved_at=null
    where id=target_payroll_id returning * into result_row;
  end if;
  return jsonb_build_object('ok',true,'payroll',to_jsonb(result_row));
end
$$;

revoke all on function public.review_payroll(uuid,boolean,text) from public, anon;
grant execute on function public.review_payroll(uuid,boolean,text) to authenticated;

create or replace function public.mark_payroll_paid(target_payroll_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_id uuid := auth.uid();
  result_row public.payroll%rowtype;
begin
  if actor_id is null or not public.has_permission('payroll_mark_paid') then
    raise exception using errcode='42501', message='Payroll payment permission required';
  end if;
  perform set_config('app.payroll_workflow_rpc','on',true);
  update public.payroll set status='paid',paid_at=now()
  where id=target_payroll_id and status='approved'
  returning * into result_row;
  if not found then raise exception using errcode='23514', message='Only approved payroll can be paid'; end if;
  return jsonb_build_object('ok',true,'payroll',to_jsonb(result_row));
end
$$;

revoke all on function public.mark_payroll_paid(uuid) from public, anon;
grant execute on function public.mark_payroll_paid(uuid) to authenticated;

create or replace function public.guard_payroll_status_transition()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status is distinct from old.status
     and coalesce(current_setting('app.payroll_workflow_rpc',true),'')<>'on' then
    raise exception using errcode='42501', message='Use protected payroll workflow';
  end if;
  if old.status in ('approved','paid')
     and coalesce(current_setting('app.payroll_workflow_rpc',true),'')<>'on'
     and row(new.base_salary,new.housing_allowance,new.transport_allowance,new.other_allowance,
             new.overtime_hours,new.overtime_rate,new.deductions,new.deduction_reason,
             new.bonuses,new.bonus_reason,new.advances,new.advance_reason,new.notes,
             new.scheduled_work_days,new.scheduled_minutes,new.attended_days,new.absence_days,
             new.attendance_source,new.attendance_reviewed_by,new.attendance_reviewed_at)
         is distinct from
         row(old.base_salary,old.housing_allowance,old.transport_allowance,old.other_allowance,
             old.overtime_hours,old.overtime_rate,old.deductions,old.deduction_reason,
             old.bonuses,old.bonus_reason,old.advances,old.advance_reason,old.notes,
             old.scheduled_work_days,old.scheduled_minutes,old.attended_days,old.absence_days,
             old.attendance_source,old.attendance_reviewed_by,old.attendance_reviewed_at) then
    raise exception using errcode='42501', message='Finalized payroll review is immutable';
  end if;
  return new;
end
$$;

revoke all on function public.guard_payroll_status_transition() from public, anon, authenticated;
drop trigger if exists guard_payroll_status_transition_trigger on public.payroll;
create trigger guard_payroll_status_transition_trigger
before update of status on public.payroll
for each row execute function public.guard_payroll_status_transition();

create or replace function public.enforce_payroll_review_reasons()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status in ('approved','paid') then
    if new.scheduled_work_days is null or new.scheduled_minutes is null
       or new.attended_days is null or new.absence_days is null
       or nullif(btrim(new.attendance_source),'') is null
       or new.attended_days+new.absence_days<>new.scheduled_work_days then
      raise exception using errcode='23514', message='Payroll review details are incomplete';
    end if;
    if new.deductions>0 and nullif(btrim(new.deduction_reason),'') is null then raise exception using errcode='23514', message='Deduction reason is required before approval'; end if;
    if new.advances>0 and nullif(btrim(new.advance_reason),'') is null then raise exception using errcode='23514', message='Advance reason is required before approval'; end if;
    if new.bonuses>0 and nullif(btrim(new.bonus_reason),'') is null then raise exception using errcode='23514', message='Bonus reason is required before approval'; end if;
  end if;
  return new;
end
$$;

revoke all on function public.enforce_payroll_review_reasons() from public, anon, authenticated;

commit;
