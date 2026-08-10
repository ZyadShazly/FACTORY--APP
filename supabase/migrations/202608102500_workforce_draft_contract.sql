-- Protect payroll and external-labor draft creation/deletion and derive money server-side.
begin;

alter table public.payroll add column if not exists command_id uuid;
alter table public.daily_labor add column if not exists command_id uuid;
create unique index if not exists payroll_command_uidx on public.payroll(command_id) where command_id is not null;
create unique index if not exists daily_labor_command_uidx on public.daily_labor(command_id) where command_id is not null;

create or replace function public.create_payroll_draft(target_employee uuid,target_month date,payload jsonb,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare employee_row public.employees%rowtype; saved public.payroll%rowtype;
  overtime_hours numeric:=coalesce(nullif(payload->>'overtime_hours','')::numeric,0);
  overtime_rate numeric:=coalesce(nullif(payload->>'overtime_rate','')::numeric,0);
  deductions numeric:=coalesce(nullif(payload->>'deductions','')::numeric,0);
  bonuses numeric:=coalesce(nullif(payload->>'bonuses','')::numeric,0);
  advances numeric:=coalesce(nullif(payload->>'advances','')::numeric,0);
begin
  if auth.uid() is null or not public.is_current_profile_active()
     or not (public.current_identity_role() in ('owner','manager') or public.has_permission('payroll_create')) then
    raise exception using errcode='42501',message='Payroll create permission required';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
  select * into saved from public.payroll where payroll.command_id=create_payroll_draft.command_id;
  if found then return to_jsonb(saved); end if;
  if target_month is null or date_trunc('month',target_month)::date<>target_month then raise exception using errcode='22023',message='Payroll month must be the first day of a month'; end if;
  if least(overtime_hours,overtime_rate,deductions,bonuses,advances)<0 then raise exception using errcode='22023',message='Payroll values cannot be negative'; end if;
  if deductions>0 and nullif(btrim(payload->>'deduction_reason'),'') is null then raise exception using errcode='22023',message='Deduction reason is required'; end if;
  if advances>0 and nullif(btrim(payload->>'advance_reason'),'') is null then raise exception using errcode='22023',message='Advance reason is required'; end if;
  if bonuses>0 and nullif(btrim(payload->>'bonus_reason'),'') is null then raise exception using errcode='22023',message='Bonus reason is required'; end if;
  if bonuses>0 and not (public.current_identity_role() in ('owner','manager') or public.has_permission('payroll_bonus_manage')) then raise exception using errcode='42501',message='Payroll bonus permission required'; end if;
  select * into employee_row from public.employees where id=target_employee and status='active' for update;
  if not found then raise exception using errcode='23503',message='Active employee required'; end if;
  insert into public.payroll(employee_id,payroll_month,base_salary,housing_allowance,transport_allowance,other_allowance,
    overtime_hours,overtime_rate,deductions,deduction_reason,bonuses,bonus_reason,advances,advance_reason,notes,status,created_by,command_id)
  values(employee_row.id,target_month,coalesce(employee_row.base_salary,0),coalesce(employee_row.housing_allowance,0),
    coalesce(employee_row.transport_allowance,0),coalesce(employee_row.other_allowance,0),overtime_hours,overtime_rate,
    deductions,nullif(btrim(payload->>'deduction_reason'),''),bonuses,nullif(btrim(payload->>'bonus_reason'),''),
    advances,nullif(btrim(payload->>'advance_reason'),''),nullif(btrim(payload->>'notes'),''),'draft',auth.uid(),command_id)
  returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('payroll',saved.id::text,'payroll_draft_created',auth.uid(),to_jsonb(saved),jsonb_build_object('salary_source','employee_master_snapshot'));
  return to_jsonb(saved);
end $$;

create or replace function public.delete_payroll_draft(target_payroll uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.payroll%rowtype;
begin
  if auth.uid() is null or not public.is_current_profile_active() or public.current_identity_role() not in ('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  select * into saved from public.payroll where id=target_payroll for update;
  if not found then raise exception using errcode='P0002',message='Payroll draft not found'; end if;
  if saved.status not in ('draft','rejected') or saved.actual_cost_entry_id is not null then raise exception using errcode='23514',message='Only an unposted draft or rejected payroll can be deleted'; end if;
  delete from public.payroll where id=target_payroll;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,metadata)
  values('payroll',saved.id::text,'payroll_draft_deleted',auth.uid(),to_jsonb(saved),jsonb_build_object('status',saved.status));
  return to_jsonb(saved);
end $$;

create or replace function public.create_daily_labor_draft(payload jsonb,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.daily_labor%rowtype; finance_allowed boolean;
  hourly numeric:=coalesce(nullif(payload->>'hourly_rate','')::numeric,0);
  overtime numeric:=coalesce(nullif(payload->>'overtime_hours','')::numeric,0);
  overtime_rate numeric:=coalesce(nullif(payload->>'overtime_rate','')::numeric,0);
  addition numeric:=coalesce(nullif(payload->>'addition_amount','')::numeric,0);
  deduction numeric:=coalesce(nullif(payload->>'deduction_amount','')::numeric,0);
  project uuid:=nullif(payload->>'project_id','')::uuid;
begin
  if auth.uid() is null or not public.is_current_profile_active()
     or not (public.current_identity_role() in ('owner','manager') or public.has_permission('daily_labor_create')) then
    raise exception using errcode='42501',message='Daily labor create permission required';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
  select * into saved from public.daily_labor where daily_labor.command_id=create_daily_labor_draft.command_id;
  if found then return to_jsonb(saved); end if;
  if nullif(btrim(payload->>'worker_name'),'') is null then raise exception using errcode='22023',message='Worker name is required'; end if;
  if nullif(payload->>'work_date','') is null or nullif(payload->>'start_time','') is null or nullif(payload->>'end_time','') is null then raise exception using errcode='22023',message='Work date and shift times are required'; end if;
  if coalesce(nullif(payload->>'break_minutes','')::integer,0)<0 or least(hourly,overtime,overtime_rate,addition,deduction)<0 then raise exception using errcode='22023',message='Daily labor values cannot be negative'; end if;
  finance_allowed:=public.current_identity_role() in ('owner','manager','accountant') or public.has_permission('project_financials_view');
  if not finance_allowed and greatest(hourly,overtime_rate,addition,deduction)>0 then raise exception using errcode='42501',message='Daily labor financial permission required'; end if;
  if addition>0 and nullif(btrim(payload->>'addition_reason'),'') is null then raise exception using errcode='22023',message='Addition reason is required'; end if;
  if deduction>0 and nullif(btrim(payload->>'deduction_reason'),'') is null then raise exception using errcode='22023',message='Deduction reason is required'; end if;
  if project is not null and not exists(select 1 from public.projects where id=project and lifecycle not in ('closed','cancelled')) then raise exception using errcode='23503',message='Active project required'; end if;
  insert into public.daily_labor(worker_name,phone,trade,project_id,work_date,start_time,end_time,break_minutes,
    hourly_rate,overtime_hours,overtime_rate,addition_amount,addition_reason,deduction_amount,deduction_reason,
    notes,review_status,payment_status,created_by,command_id)
  values(btrim(payload->>'worker_name'),nullif(btrim(payload->>'phone'),''),nullif(btrim(payload->>'trade'),''),project,
    (payload->>'work_date')::date,(payload->>'start_time')::time,(payload->>'end_time')::time,
    coalesce(nullif(payload->>'break_minutes','')::integer,0),hourly,overtime,overtime_rate,addition,
    nullif(btrim(payload->>'addition_reason'),''),deduction,nullif(btrim(payload->>'deduction_reason'),''),
    nullif(btrim(payload->>'notes'),''),'draft','unpaid',auth.uid(),command_id)
  returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data)
  values('daily_labor',saved.id::text,'daily_labor_draft_created',auth.uid(),to_jsonb(saved));
  return to_jsonb(saved);
end $$;

create or replace function public.delete_daily_labor_draft(target_shift uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.daily_labor%rowtype;
begin
  if auth.uid() is null or not public.is_current_profile_active() or public.current_identity_role() not in ('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  select * into saved from public.daily_labor where id=target_shift for update;
  if not found then raise exception using errcode='P0002',message='Daily labor draft not found'; end if;
  if saved.review_status<>'draft' or saved.payment_status<>'unpaid' or coalesce(saved.paid_amount,0)<>0 or saved.actual_cost_entry_id is not null then raise exception using errcode='23514',message='Only an untouched daily labor draft can be deleted'; end if;
  delete from public.daily_labor where id=target_shift;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data)
  values('daily_labor',saved.id::text,'daily_labor_draft_deleted',auth.uid(),to_jsonb(saved));
  return to_jsonb(saved);
end $$;

revoke all on function public.create_payroll_draft(uuid,date,jsonb,uuid),public.delete_payroll_draft(uuid),
  public.create_daily_labor_draft(jsonb,uuid),public.delete_daily_labor_draft(uuid) from public,anon,authenticated;
grant execute on function public.create_payroll_draft(uuid,date,jsonb,uuid),public.delete_payroll_draft(uuid),
  public.create_daily_labor_draft(jsonb,uuid),public.delete_daily_labor_draft(uuid) to authenticated;

revoke insert,update,delete on table public.payroll,public.daily_labor from anon,authenticated;

commit;
