begin;

alter table public.work_schedules
  add column if not exists rejection_reason text,
  add column if not exists rejected_at timestamptz,
  add column if not exists rejected_by uuid references public.profiles(id) on delete set null;

alter table public.work_schedules drop constraint if exists work_schedules_status_check;
alter table public.work_schedules add constraint work_schedules_status_check
  check (status in ('draft','active','superseded','cancelled','rejected'));

create or replace function public.get_work_schedule_review_context(target_schedule_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  target_row public.work_schedules%rowtype;
  active_row public.work_schedules%rowtype;
  affected_employees integer := 0;
  draft_payroll integer := 0;
  locked_payroll integer := 0;
begin
  if auth.uid() is null or not public.has_permission('payroll_calendar_view') then
    raise exception using errcode='42501', message='Calendar view permission required';
  end if;

  select * into target_row from public.work_schedules where id=target_schedule_id;
  if not found then raise exception using errcode='P0002', message='Work schedule was not found'; end if;

  select * into active_row
  from public.work_schedules s
  where s.status='active'
    and s.scope_type=target_row.scope_type
    and s.department_id is not distinct from target_row.department_id
    and s.employee_id is not distinct from target_row.employee_id
    and s.id<>target_row.id
  order by s.revision_number desc
  limit 1;

  select count(*)::integer into affected_employees
  from public.employees e
  where e.status='active'
    and (
      target_row.scope_type='company'
      or target_row.scope_type='department' and e.department_id=target_row.department_id
      or target_row.scope_type='employee' and e.id=target_row.employee_id
    );

  select count(*) filter (where p.status='draft')::integer,
         count(*) filter (where p.status in ('approved','paid'))::integer
    into draft_payroll, locked_payroll
  from public.payroll p
  join public.employees e on e.id=p.employee_id
  where (
      target_row.scope_type='company'
      or target_row.scope_type='department' and e.department_id=target_row.department_id
      or target_row.scope_type='employee' and e.id=target_row.employee_id
    )
    and p.payroll_month <= coalesce(target_row.effective_to,'9999-12-31'::date)
    and (p.payroll_month + interval '1 month - 1 day')::date >= target_row.effective_from;

  return jsonb_build_object(
    'schedule', to_jsonb(target_row),
    'days', coalesce((select jsonb_agg(to_jsonb(d) order by d.iso_weekday) from public.work_schedule_days d where d.schedule_id=target_row.id),'[]'::jsonb),
    'active_schedule', case when active_row.id is null then null else to_jsonb(active_row) end,
    'active_days', coalesce((select jsonb_agg(to_jsonb(d) order by d.iso_weekday) from public.work_schedule_days d where d.schedule_id=active_row.id),'[]'::jsonb),
    'affected_employees', affected_employees,
    'draft_payroll_count', draft_payroll,
    'locked_payroll_count', locked_payroll
  );
end
$$;

revoke all on function public.get_work_schedule_review_context(uuid) from public, anon;
grant execute on function public.get_work_schedule_review_context(uuid) to authenticated;

create or replace function public.reject_work_schedule(target_schedule_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_row public.work_schedules%rowtype;
  clean_reason text := nullif(btrim(reason),'');
begin
  if actor is null or not public.has_permission('payroll_calendar_approve') then
    raise exception using errcode='42501', message='Calendar approval permission required';
  end if;
  if clean_reason is null then raise exception using errcode='23514', message='Rejection reason is required'; end if;

  select * into target_row from public.work_schedules where id=target_schedule_id for update;
  if not found then raise exception using errcode='P0002', message='Work schedule was not found'; end if;
  if target_row.status<>'draft' then raise exception using errcode='23514', message='Only a draft work schedule can be rejected'; end if;

  update public.work_schedules
     set status='rejected', rejection_reason=clean_reason, rejected_at=now(), rejected_by=actor,
         updated_at=now(), updated_by=actor
   where id=target_schedule_id
   returning * into target_row;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('work_schedules',target_row.id::text,'reject',actor,to_jsonb(target_row),jsonb_build_object('reason',clean_reason));

  return jsonb_build_object('ok',true,'schedule',to_jsonb(target_row));
end
$$;

revoke all on function public.reject_work_schedule(uuid,text) from public, anon;
grant execute on function public.reject_work_schedule(uuid,text) to authenticated;

create or replace function public.cancel_work_schedule(target_schedule_id uuid, cancellation_date date, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor uuid := auth.uid();
  target_row public.work_schedules%rowtype;
  clean_reason text := nullif(btrim(reason),'');
  new_version bigint;
  impact jsonb;
begin
  if actor is null or not public.has_permission('payroll_calendar_approve') then
    raise exception using errcode='42501', message='Calendar approval permission required';
  end if;
  if clean_reason is null then raise exception using errcode='23514', message='Cancellation reason is required'; end if;
  if cancellation_date is null then raise exception using errcode='23514', message='Cancellation effective date is required'; end if;
  if cancellation_date>current_date then raise exception using errcode='23514', message='Future cancellation requires a replacement schedule first'; end if;

  select * into target_row from public.work_schedules where id=target_schedule_id for update;
  if not found then raise exception using errcode='P0002', message='Work schedule was not found'; end if;
  if target_row.status<>'active' then raise exception using errcode='23514', message='Only an active work schedule can be cancelled'; end if;
  if cancellation_date<target_row.effective_from then raise exception using errcode='23514', message='Cancellation date cannot precede schedule start'; end if;

  impact := public.get_work_schedule_review_context(target_schedule_id);
  new_version := nextval('public.payroll_calendar_version_seq');
  perform set_config('app.calendar_workflow','on',true);

  update public.work_schedules
     set status='cancelled', effective_to=least(coalesce(effective_to,cancellation_date),cancellation_date),
         valid_to_version=new_version, cancellation_reason=clean_reason, cancelled_at=now(), cancelled_by=actor,
         updated_at=now(), updated_by=actor
   where id=target_schedule_id
   returning * into target_row;

  perform public.mark_payroll_calendar_stale(target_row.effective_from,cancellation_date,new_version);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('work_schedules',target_row.id::text,'cancel',actor,to_jsonb(target_row),jsonb_build_object('reason',clean_reason,'effective_date',cancellation_date,'calendar_version',new_version));

  return jsonb_build_object('ok',true,'calendar_version',new_version,'schedule',to_jsonb(target_row),'impact',impact);
end
$$;

revoke all on function public.cancel_work_schedule(uuid,date,text) from public, anon;
grant execute on function public.cancel_work_schedule(uuid,date,text) to authenticated;

commit;
