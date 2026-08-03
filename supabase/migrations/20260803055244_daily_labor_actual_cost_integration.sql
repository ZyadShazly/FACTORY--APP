-- Post approved daily-labor net settlements through the protected Actual Cost workflow.
begin;

create or replace function private.guard_daily_labor_settlement()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  correction_call boolean := coalesce(current_setting('app.daily_labor_correction',true),'') = 'on';
  review_call boolean := coalesce(current_setting('app.daily_labor_review',true),'') = 'on';
  payment_call boolean := coalesce(current_setting('app.daily_labor_payment',true),'') = 'on';
  cost_call boolean := coalesce(current_setting('app.daily_labor_actual_cost',true),'') = 'on';
begin
  if old.review_status <> 'draft' and not correction_call and (
    new.worker_name is distinct from old.worker_name
    or new.phone is distinct from old.phone
    or new.trade is distinct from old.trade
    or new.project_id is distinct from old.project_id
    or new.work_date is distinct from old.work_date
    or new.start_time is distinct from old.start_time
    or new.end_time is distinct from old.end_time
    or new.break_minutes is distinct from old.break_minutes
    or new.hourly_rate is distinct from old.hourly_rate
    or new.overtime_hours is distinct from old.overtime_hours
    or new.overtime_rate is distinct from old.overtime_rate
    or new.addition_amount is distinct from old.addition_amount
    or new.addition_reason is distinct from old.addition_reason
    or new.deduction_amount is distinct from old.deduction_amount
    or new.deduction_reason is distinct from old.deduction_reason
    or new.notes is distinct from old.notes
  ) then
    raise exception using errcode='23514',
      message='Reviewed daily labor settlement is immutable; use correction workflow';
  end if;

  if not (review_call or correction_call) and (
    new.review_status is distinct from old.review_status
    or new.reviewed_by is distinct from old.reviewed_by
    or new.reviewed_at is distinct from old.reviewed_at
    or new.rejection_reason is distinct from old.rejection_reason
  ) then
    raise exception using errcode='42501',
      message='Daily labor review fields can only change through review workflow';
  end if;

  if not payment_call and (
    new.payment_status is distinct from old.payment_status
    or new.paid_amount is distinct from old.paid_amount
    or new.payment_reference is distinct from old.payment_reference
    or new.payment_notes is distinct from old.payment_notes
    or new.paid_by is distinct from old.paid_by
    or new.paid_at is distinct from old.paid_at
  ) then
    raise exception using errcode='42501',
      message='Daily labor payment fields can only change through payment workflow';
  end if;

  if not correction_call and (
    new.correction_count is distinct from old.correction_count
    or new.last_correction_reason is distinct from old.last_correction_reason
    or new.last_corrected_by is distinct from old.last_corrected_by
    or new.last_corrected_at is distinct from old.last_corrected_at
  ) then
    raise exception using errcode='42501',
      message='Daily labor correction audit fields are immutable';
  end if;

  if not cost_call and (
    new.actual_cost_entry_id is distinct from old.actual_cost_entry_id
    or new.cost_posting_status is distinct from old.cost_posting_status
    or new.cost_posted_at is distinct from old.cost_posted_at
    or new.cost_posted_by is distinct from old.cost_posted_by
  ) then
    raise exception using errcode='42501',
      message='Daily labor Actual Cost fields can only change through protected cost workflow';
  end if;

  return new;
end $$;

revoke all on function private.guard_daily_labor_settlement()
  from public,anon,authenticated;

create or replace function private.validate_actual_cost_source_controls()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor_role text := public.current_identity_role();
  operational_call boolean := coalesce(current_setting('app.operational_actual_cost',true),'') = 'on';
begin
  if new.source_type in ('material_purchase','daily_labor','payroll_allocation','approved_expense')
     and not operational_call then
    raise exception using errcode='42501',
      message='Operational Actual Cost sources must use the protected source workflow';
  end if;
  if new.source_type='manual_adjustment' and auth.uid() is not null and actor_role <> 'owner' then
    raise exception 'Only Owner may create manual actual cost adjustments';
  end if;
  if new.source_type='warehouse_issue_line' and new.cost_category <> 'material' then
    raise exception 'Warehouse issue costs must use the material category';
  end if;
  if new.source_type='factory_labor_allocation' and new.cost_category <> 'labor' then
    raise exception 'Factory labor allocations must use the labor category';
  end if;
  if new.source_type='asset_consumption_line' and new.cost_category <> 'asset_consumption' then
    raise exception 'Asset consumption costs must use the asset_consumption category';
  end if;
  if new.source_type='employee_cash_custody_settlement_line' and new.cost_category <> 'employee_cash_custody' then
    raise exception 'Employee cash custody settlements must use the employee_cash_custody category';
  end if;
  if new.source_type='petty_cash_settlement_line' and new.cost_category <> 'petty_cash' then
    raise exception 'Petty cash settlements must use the petty_cash category';
  end if;
  return new;
end $$;

revoke all on function private.validate_actual_cost_source_controls()
  from public,anon,authenticated;

create or replace function public.prepare_operational_source_actual_cost(target_source_type text, target_source_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid := auth.uid();
  role_name text := public.current_identity_role();
  p_project uuid;
  p_amount numeric;
  p_date date;
  p_description text;
  p_category text;
  p_quantity numeric := 1;
  p_unit text := 'وحدة';
  p_unit_cost numeric;
  existing_entry uuid;
  p_review_status text;
  p_cost_status text;
  p_gross numeric;
  p_addition numeric;
  p_deduction numeric;
  p_metadata jsonb := jsonb_build_object('operational_source',true);
  saved public.project_actual_cost_entries%rowtype;
begin
  if actor is null or not public.is_current_profile_active()
     or role_name not in ('owner','manager','accountant') then
    raise exception using errcode='42501',message='Owner, manager, or accountant role required';
  end if;

  if target_source_type = 'material_purchase' then
    select project_id,round(qty*unit_cost,2),coalesce(purchase_date,current_date),
           coalesce(note,'شراء خامات للمشروع'),qty,
           coalesce((select unit from public.materials where id=material_id),'وحدة'),unit_cost,
           actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.material_purchases where id=target_source_id for update;
    p_category := 'material';
  elsif target_source_type = 'daily_labor' then
    select project_id,net_amount,work_date,
           concat('عمالة يومية: ',worker_name,coalesce(' - '||trade,''),' - صافي التسوية'),
           1,'يوم',net_amount,actual_cost_entry_id,review_status,cost_posting_status,
           total_amount,addition_amount,deduction_amount
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,
           existing_entry,p_review_status,p_cost_status,p_gross,p_addition,p_deduction
    from public.daily_labor where id=target_source_id for update;
    if not found then
      raise exception using errcode='P0002',message='Daily labor shift was not found';
    end if;
    if p_review_status <> 'approved' then
      raise exception using errcode='23514',message='Daily labor shift must be approved before Actual Cost submission';
    end if;
    if coalesce(p_cost_status,'not_posted') <> 'not_posted' then
      raise exception using errcode='23514',message='Daily labor shift is already in the Actual Cost workflow';
    end if;
    p_category := 'labor';
    p_metadata := p_metadata || jsonb_build_object(
      'settlement_basis','net_amount',
      'gross_amount',p_gross,
      'addition_amount',p_addition,
      'deduction_amount',p_deduction
    );
  elsif target_source_type = 'payroll_allocation' then
    select project_id,net_salary,payroll_month,
           concat('توزيع راتب: ',coalesce((select full_name from public.employees where id=employee_id),'موظف'),' - ',to_char(payroll_month,'YYYY-MM')),
           1,'شهر',net_salary,actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.payroll where id=target_source_id and status in ('approved','paid') for update;
    p_category := 'labor';
  elsif target_source_type = 'approved_expense' then
    select project_id,amount,expense_date,concat('مصروف مشروع: ',category),1,'مصروف',amount,actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.expenses where id=target_source_id for update;
    p_category := case when lower(category) like '%نقل%' or lower(category) like '%transport%' then 'transport' else 'other' end;
  else
    raise exception using errcode='22023',message='Unsupported operational source type';
  end if;

  if p_project is null then raise exception using errcode='23514',message='Source must be linked to a project'; end if;
  if p_amount is null or p_amount <= 0 then raise exception using errcode='23514',message='Source amount must be greater than zero'; end if;
  if existing_entry is not null then raise exception using errcode='23514',message='Source is already linked to an Actual Cost entry'; end if;
  if not private.project_can_view(p_project) then raise exception using errcode='42501',message='Project access denied'; end if;
  perform private.actual_cost_assert_mutable(p_project,p_date);

  perform set_config('app.operational_actual_cost','on',true);
  if target_source_type='daily_labor' then
    -- The status-sync trigger runs during the insert, before this function's
    -- explicit source update, so enable the guarded source workflow first.
    perform set_config('app.daily_labor_actual_cost','on',true);
  end if;
  insert into public.project_actual_cost_entries(
    project_id,cost_category,source_type,source_id,source_line_reference,source_revision,source_reference_key,
    description,quantity,unit,unit_cost,cost_date,status,submitted_by,submitted_at,created_by,updated_by,metadata
  ) values (
    p_project,p_category,target_source_type,target_source_id,'main',1,
    target_source_type||':'||target_source_id::text||':main:1',p_description,p_quantity,p_unit,p_unit_cost,p_date,
    'submitted',actor,now(),actor,actor,p_metadata
  ) returning * into saved;

  if target_source_type='material_purchase' then
    update public.material_purchases set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  elsif target_source_type='daily_labor' then
    update public.daily_labor set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  elsif target_source_type='payroll_allocation' then
    update public.payroll set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  else
    update public.expenses set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  end if;

  return to_jsonb(saved);
end $$;

revoke all on function public.prepare_operational_source_actual_cost(text,uuid)
  from public,anon,authenticated;
grant execute on function public.prepare_operational_source_actual_cost(text,uuid) to authenticated;

create or replace function private.sync_operational_source_actual_cost_status()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  next_status text;
begin
  if new.source_type not in ('material_purchase','daily_labor','payroll_allocation','approved_expense') then
    return new;
  end if;

  next_status := case new.status
    when 'submitted' then 'submitted'
    when 'approved' then 'posted'
    when 'rejected' then 'rejected'
    when 'reversed' then 'reversed'
    else 'not_posted'
  end;

  if new.source_type='material_purchase' then
    update public.material_purchases
    set actual_cost_entry_id=new.id,cost_posting_status=next_status,
        cost_posted_at=case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
        cost_posted_by=case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
    where id=new.source_id;
  elsif new.source_type='daily_labor' then
    perform set_config('app.daily_labor_actual_cost','on',true);
    update public.daily_labor
    set actual_cost_entry_id=new.id,cost_posting_status=next_status,
        cost_posted_at=case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
        cost_posted_by=case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
    where id=new.source_id;
  elsif new.source_type='payroll_allocation' then
    update public.payroll
    set actual_cost_entry_id=new.id,cost_posting_status=next_status,
        cost_posted_at=case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
        cost_posted_by=case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
    where id=new.source_id;
  else
    update public.expenses
    set actual_cost_entry_id=new.id,cost_posting_status=next_status,
        cost_posted_at=case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
        cost_posted_by=case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
    where id=new.source_id;
  end if;

  return new;
end $$;

revoke all on function private.sync_operational_source_actual_cost_status()
  from public,anon,authenticated;

comment on function public.prepare_operational_source_actual_cost(text,uuid) is
  'Intentional authenticated Actual Cost submission API. Validates active finance role, project access, source state, row lock, and one-time source linkage.';

commit;
