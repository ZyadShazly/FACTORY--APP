-- Operational source integrations for Project Actual Cost.
-- Safe after 202607190009. Existing source rows are preserved and remain unposted.

begin;

alter table public.material_purchases
  add column if not exists actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete set null,
  add column if not exists cost_posting_status text not null default 'not_posted',
  add column if not exists cost_posted_at timestamptz,
  add column if not exists cost_posted_by uuid references public.profiles(id) on delete set null;

alter table public.daily_labor
  add column if not exists actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete set null,
  add column if not exists cost_posting_status text not null default 'not_posted',
  add column if not exists cost_posted_at timestamptz,
  add column if not exists cost_posted_by uuid references public.profiles(id) on delete set null;

alter table public.payroll
  add column if not exists actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete set null,
  add column if not exists cost_posting_status text not null default 'not_posted',
  add column if not exists cost_posted_at timestamptz,
  add column if not exists cost_posted_by uuid references public.profiles(id) on delete set null;

alter table public.expenses
  add column if not exists actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete set null,
  add column if not exists cost_posting_status text not null default 'not_posted',
  add column if not exists cost_posted_at timestamptz,
  add column if not exists cost_posted_by uuid references public.profiles(id) on delete set null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname='material_purchases_cost_posting_status_check') then
    alter table public.material_purchases add constraint material_purchases_cost_posting_status_check check (cost_posting_status in ('not_posted','submitted','posted','rejected','reversed'));
  end if;
  if not exists (select 1 from pg_constraint where conname='daily_labor_cost_posting_status_check') then
    alter table public.daily_labor add constraint daily_labor_cost_posting_status_check check (cost_posting_status in ('not_posted','submitted','posted','rejected','reversed'));
  end if;
  if not exists (select 1 from pg_constraint where conname='payroll_cost_posting_status_check') then
    alter table public.payroll add constraint payroll_cost_posting_status_check check (cost_posting_status in ('not_posted','submitted','posted','rejected','reversed'));
  end if;
  if not exists (select 1 from pg_constraint where conname='expenses_cost_posting_status_check') then
    alter table public.expenses add constraint expenses_cost_posting_status_check check (cost_posting_status in ('not_posted','submitted','posted','rejected','reversed'));
  end if;
end $$;

alter table public.project_actual_cost_entries drop constraint if exists project_actual_cost_entries_source_type_check;
alter table public.project_actual_cost_entries add constraint project_actual_cost_entries_source_type_check check (source_type in (
  'purchase_invoice_line','warehouse_issue_line','asset_consumption_line','factory_labor_allocation',
  'employee_cash_custody_settlement_line','petty_cash_settlement_line','manual_adjustment','legacy_project_cost',
  'material_purchase','daily_labor','payroll_allocation','approved_expense'
));

insert into public.project_cost_source_contracts(source_type,posting_event,required_state,allowed_links,double_count_group,description,active)
values
 ('material_purchase','source submitted then approved','submitted',array['project','milestone','budget_item'],'material_purchase','Project-linked material purchase posted once by source row.',true),
 ('daily_labor','source submitted then approved','submitted',array['project','milestone','budget_item'],'daily_labor','Project-linked daily labor posted once by source row.',true),
 ('payroll_allocation','approved payroll allocation submitted then approved','approved_or_paid',array['project','milestone','budget_item'],'payroll_allocation','Only approved or paid payroll explicitly linked to one project may post.',true),
 ('approved_expense','source submitted then approved','submitted',array['project','milestone','budget_item'],'approved_expense','Project expense requires Actual Cost workflow approval before posting.',true)
on conflict(source_type) do update set
 posting_event=excluded.posting_event,
 required_state=excluded.required_state,
 allowed_links=excluded.allowed_links,
 double_count_group=excluded.double_count_group,
 description=excluded.description,
 active=true;

create or replace function public.prepare_operational_source_actual_cost(target_source_type text, target_source_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
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
  saved public.project_actual_cost_entries%rowtype;
begin
  if actor is null or role_name not in ('owner','manager','accountant') then
    raise exception 'Owner, manager, or accountant role required';
  end if;

  if target_source_type = 'material_purchase' then
    select project_id, round(qty*unit_cost,2), coalesce(purchase_date,current_date),
           coalesce(note,'شراء خامات للمشروع'), qty, coalesce((select unit from public.materials where id=material_id),'وحدة'), unit_cost,
           actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.material_purchases where id=target_source_id for update;
    p_category := 'material';
  elsif target_source_type = 'daily_labor' then
    select project_id, total_amount, work_date,
           concat('عمالة يومية: ',worker_name,coalesce(' - '||trade,'')), 1, 'يوم', total_amount,
           actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.daily_labor where id=target_source_id for update;
    p_category := 'labor';
  elsif target_source_type = 'payroll_allocation' then
    select project_id, net_salary, payroll_month,
           concat('توزيع راتب: ',coalesce((select full_name from public.employees where id=employee_id),'موظف'),' - ',to_char(payroll_month,'YYYY-MM')),
           1, 'شهر', net_salary, actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.payroll where id=target_source_id and status in ('approved','paid') for update;
    p_category := 'labor';
  elsif target_source_type = 'approved_expense' then
    select project_id, amount, expense_date, concat('مصروف مشروع: ',category), 1, 'مصروف', amount, actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.expenses where id=target_source_id for update;
    p_category := case when lower(category) like '%نقل%' or lower(category) like '%transport%' then 'transport' else 'other' end;
  else
    raise exception 'Unsupported operational source type';
  end if;

  if p_project is null then raise exception 'Source must be linked to a project'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Source amount must be greater than zero'; end if;
  if existing_entry is not null then raise exception 'Source is already linked to an Actual Cost entry'; end if;
  if not private.project_can_view(p_project) then raise exception 'Project access denied'; end if;
  perform private.actual_cost_assert_mutable(p_project,p_date);

  insert into public.project_actual_cost_entries(
    project_id,cost_category,source_type,source_id,source_line_reference,source_revision,source_reference_key,
    description,quantity,unit,unit_cost,cost_date,status,submitted_by,submitted_at,created_by,updated_by,metadata
  ) values (
    p_project,p_category,target_source_type,target_source_id,'main',1,
    target_source_type||':'||target_source_id::text||':main:1',p_description,p_quantity,p_unit,p_unit_cost,p_date,
    'submitted',actor,now(),actor,actor,jsonb_build_object('operational_source',true)
  ) returning * into saved;

  if target_source_type='material_purchase' then update public.material_purchases set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  elsif target_source_type='daily_labor' then update public.daily_labor set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  elsif target_source_type='payroll_allocation' then update public.payroll set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  else update public.expenses set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  end if;

  return to_jsonb(saved);
end $$;

create or replace function public.approve_operational_source_actual_cost(target_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.project_actual_cost_entries%rowtype;
  result jsonb;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then
    raise exception 'Owner or manager role required';
  end if;
  select * into saved from public.project_actual_cost_entries where id=target_entry_id for update;
  if not found then raise exception 'Actual Cost entry not found'; end if;
  if saved.source_type not in ('material_purchase','daily_labor','payroll_allocation','approved_expense') then
    raise exception 'Entry is not an operational source integration';
  end if;

  result := public.approve_project_actual_cost(target_entry_id);

  if saved.source_type='material_purchase' then update public.material_purchases set cost_posting_status='posted',cost_posted_at=now(),cost_posted_by=actor where id=saved.source_id;
  elsif saved.source_type='daily_labor' then update public.daily_labor set cost_posting_status='posted',cost_posted_at=now(),cost_posted_by=actor where id=saved.source_id;
  elsif saved.source_type='payroll_allocation' then update public.payroll set cost_posting_status='posted',cost_posted_at=now(),cost_posted_by=actor where id=saved.source_id;
  else update public.expenses set cost_posting_status='posted',cost_posted_at=now(),cost_posted_by=actor where id=saved.source_id;
  end if;

  return result;
end $$;

create or replace function public.reject_operational_source_actual_cost(target_entry_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  saved public.project_actual_cost_entries%rowtype;
  result jsonb;
begin
  select * into saved from public.project_actual_cost_entries where id=target_entry_id for update;
  if not found then raise exception 'Actual Cost entry not found'; end if;
  if saved.source_type not in ('material_purchase','daily_labor','payroll_allocation','approved_expense') then
    raise exception 'Entry is not an operational source integration';
  end if;
  result := public.reject_project_actual_cost(target_entry_id,reason);
  if saved.source_type='material_purchase' then update public.material_purchases set cost_posting_status='rejected' where id=saved.source_id;
  elsif saved.source_type='daily_labor' then update public.daily_labor set cost_posting_status='rejected' where id=saved.source_id;
  elsif saved.source_type='payroll_allocation' then update public.payroll set cost_posting_status='rejected' where id=saved.source_id;
  else update public.expenses set cost_posting_status='rejected' where id=saved.source_id;
  end if;
  return result;
end $$;

create index if not exists material_purchases_actual_cost_entry_idx on public.material_purchases(actual_cost_entry_id) where actual_cost_entry_id is not null;
create index if not exists daily_labor_actual_cost_entry_idx on public.daily_labor(actual_cost_entry_id) where actual_cost_entry_id is not null;
create index if not exists payroll_actual_cost_entry_idx on public.payroll(actual_cost_entry_id) where actual_cost_entry_id is not null;
create index if not exists expenses_actual_cost_entry_idx on public.expenses(actual_cost_entry_id) where actual_cost_entry_id is not null;

revoke all on function public.prepare_operational_source_actual_cost(text,uuid) from public,anon;
revoke all on function public.approve_operational_source_actual_cost(uuid) from public,anon;
revoke all on function public.reject_operational_source_actual_cost(uuid,text) from public,anon;
grant execute on function public.prepare_operational_source_actual_cost(text,uuid) to authenticated;
grant execute on function public.approve_operational_source_actual_cost(uuid) to authenticated;
grant execute on function public.reject_operational_source_actual_cost(uuid,text) to authenticated;

commit;
