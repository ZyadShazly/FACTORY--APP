-- Cash custody settlements must post to an explicitly selected expense account.

begin;

alter table public.employee_cash_custody_settlements
  add column if not exists expense_account_id uuid references public.accounting_accounts(id) on delete restrict;

update public.employee_cash_custody_settlements s
set expense_account_id=m.account_id
from public.accounting_account_mappings m
where s.expense_account_id is null
  and lower(btrim(m.mapping_key))='expense_default'
  and lower(btrim(m.scope_type))='global'
  and btrim(m.scope_value)=''
  and m.is_active;

do $$
begin
  if exists(select 1 from public.employee_cash_custody_settlements where expense_account_id is null) then
    raise exception using errcode='23514',message='Existing cash custody settlements require an expense account before migration can continue';
  end if;
end
$$;

alter table public.employee_cash_custody_settlements
  alter column expense_account_id set not null;

create index if not exists employee_cash_custody_settlements_expense_account_idx
  on public.employee_cash_custody_settlements(expense_account_id);

create or replace function private.accounting_assert_expense_posting_account(target_account uuid)
returns uuid
language plpgsql
stable
security definer
set search_path=''
as $$
declare account_row public.accounting_accounts%rowtype;
begin
  select * into account_row
  from public.accounting_accounts
  where id=target_account;

  if not found then
    raise exception using errcode='23503',message='Expense account was not found';
  end if;
  if not account_row.is_active or not account_row.is_posting or account_row.account_type<>'expense' then
    raise exception using errcode='23514',message='Selected expense account must be an active posting expense account';
  end if;

  return account_row.id;
end
$$;
revoke all on function private.accounting_assert_expense_posting_account(uuid) from public,anon,authenticated;

create or replace function public.get_expense_posting_accounts()
returns table(
  id uuid,
  account_code text,
  name_ar text,
  name_en text
)
language sql
stable
security definer
set search_path=''
as $$
  select a.id,a.account_code,a.name_ar,a.name_en
  from public.accounting_accounts a
  where a.account_type='expense'
    and a.is_active
    and a.is_posting
  order by a.account_code
$$;
revoke all on function public.get_expense_posting_accounts() from public,anon;
grant execute on function public.get_expense_posting_accounts() to authenticated;

drop function if exists public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid);

create function public.record_employee_cash_custody_settlement(
  target_custody uuid,
  expense_amount numeric,
  expense_category text,
  settled_on date default current_date,
  expense_notes text default null,
  command_id uuid default gen_random_uuid(),
  expense_account uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  custody public.employee_cash_custodies%rowtype;
  saved public.employee_cash_custody_settlements%rowtype;
  remaining numeric;
  actual_entry jsonb;
  actor uuid:=auth.uid();
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if expense_amount is null or expense_amount<=0 then
    raise exception using errcode='22023',message='Settlement expense amount must be positive';
  end if;
  if nullif(btrim(expense_category),'') is null then
    raise exception using errcode='22023',message='Expense category is required';
  end if;
  if expense_account is null then
    raise exception using errcode='22023',message='Expense account is required';
  end if;
  if command_id is null then
    raise exception using errcode='22023',message='Command id is required';
  end if;

  perform private.accounting_assert_expense_posting_account(expense_account);

  select * into saved
  from public.employee_cash_custody_settlements
  where employee_cash_custody_settlements.command_id=record_employee_cash_custody_settlement.command_id;
  if found then
    return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(saved.custody_id));
  end if;

  select * into custody
  from public.employee_cash_custodies
  where id=target_custody
  for update;

  if not found then
    raise exception using errcode='P0002',message='Cash custody was not found';
  end if;
  if custody.status='settled' then
    raise exception using errcode='23514',message='Cash custody is already settled';
  end if;
  if coalesce(settled_on,current_date)<custody.issued_on then
    raise exception using errcode='23514',message='Settlement date cannot be before cash custody issue date';
  end if;

  remaining:=private.employee_cash_custody_remaining(custody.id);
  if round(expense_amount,2)>remaining then
    raise exception using errcode='23514',message='Settlement exceeds remaining cash custody balance';
  end if;

  insert into public.employee_cash_custody_settlements(
    custody_id,expense_category,expense_account_id,amount,settled_on,notes,command_id,approved_by,created_by
  ) values(
    custody.id,btrim(expense_category),expense_account,round(expense_amount,2),coalesce(settled_on,current_date),
    nullif(btrim(expense_notes),''),command_id,actor,actor
  ) returning * into saved;

  if custody.project_id is not null then
    actual_entry:=public.save_project_actual_cost(jsonb_build_object(
      'project_id',custody.project_id,
      'cost_category','employee_cash_custody',
      'source_type','employee_cash_custody_settlement_line',
      'source_id',saved.id,
      'source_line_reference','main',
      'source_revision',1,
      'source_reference_key','employee_cash_custody_settlement_line:'||saved.id::text||':main:1',
      'description',concat('تسوية عهدة ',custody.custody_number,' — ',saved.expense_category),
      'quantity',1,
      'unit','تسوية',
      'unit_cost',saved.amount,
      'cost_date',saved.settled_on,
      'metadata',jsonb_build_object(
        'custody_id',custody.id,
        'employee_id',custody.employee_id,
        'expense_account_id',saved.expense_account_id
      )
    ));
    perform public.submit_project_actual_cost((actual_entry->>'id')::uuid);
    perform public.approve_project_actual_cost((actual_entry->>'id')::uuid);
    update public.employee_cash_custody_settlements
    set actual_cost_entry_id=(actual_entry->>'id')::uuid
    where id=saved.id
    returning * into saved;
  end if;

  perform private.refresh_employee_cash_custody_status(custody.id);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'employee_cash_custody_settlements',
    saved.id::text,
    'employee_cash_custody_settlement_approved',
    actor,
    to_jsonb(saved),
    jsonb_build_object(
      'custody_id',custody.id,
      'expense_account_id',saved.expense_account_id,
      'remaining_amount',private.employee_cash_custody_remaining(custody.id)
    )
  );

  return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(custody.id));
end
$$;
revoke all on function public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid,uuid) from public,anon;
grant execute on function public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid,uuid) to authenticated;

create or replace function private.accounting_employee_cash_custody_settlement_gl()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  custody public.employee_cash_custodies%rowtype;
  advance_account uuid;
  reference_value text;
begin
  select * into custody
  from public.employee_cash_custodies
  where id=new.custody_id;

  if not found then
    raise exception using errcode='23503',message='Cash custody was not found for settlement';
  end if;
  if not private.accounting_source_event_in_scope(new.settled_on) then
    return new;
  end if;

  advance_account:=private.accounting_resolve_mapping('employee_advances_receivable','global','');
  perform private.accounting_assert_expense_posting_account(new.expense_account_id);
  reference_value:=custody.custody_number||'/SET/'||left(new.id::text,8);

  perform private.accounting_post_source_journal(
    'employee_cash_custody',
    'custody_settlement_posted',
    new.id::text,
    new.settled_on,
    'تسوية عهدة نقدية — '||new.expense_category,
    reference_value,
    custody.project_id,
    jsonb_build_array(
      jsonb_build_object(
        'account_id',new.expense_account_id,
        'debit',new.amount,
        'credit',0,
        'description',new.expense_category,
        'partner_type','employee',
        'partner_id',custody.employee_id,
        'project_id',custody.project_id,
        'source_line_id','expense',
        'reference',reference_value
      ),
      jsonb_build_object(
        'account_id',advance_account,
        'debit',0,
        'credit',new.amount,
        'description','تسوية رصيد عهدة الموظف',
        'partner_type','employee',
        'partner_id',custody.employee_id,
        'project_id',custody.project_id,
        'source_line_id','employee_advance',
        'reference',reference_value
      )
    ),
    coalesce(auth.uid(),new.created_by)
  );

  return new;
end
$$;
revoke all on function private.accounting_employee_cash_custody_settlement_gl() from public,anon,authenticated;

create or replace function public.get_employee_cash_custody_workspace()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;

  select jsonb_build_object(
    'custodies',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',c.id,
        'custody_number',c.custody_number,
        'employee_id',c.employee_id,
        'employee_name',e.full_name,
        'project_id',c.project_id,
        'project_code',p.project_code,
        'project_name',p.project_name,
        'issued_amount',c.issued_amount,
        'issued_on',c.issued_on,
        'cash_bank_account_id',c.cash_bank_account_id,
        'cash_bank_account_code',a.account_code,
        'cash_bank_account_name',coalesce(a.name_ar,a.name_en),
        'notes',c.notes,
        'status',c.status,
        'settled_amount',coalesce((select sum(s.amount) from public.employee_cash_custody_settlements s where s.custody_id=c.id and s.status='approved'),0),
        'returned_amount',coalesce((select sum(r.amount) from public.employee_cash_custody_returns r where r.custody_id=c.id),0),
        'remaining_amount',private.employee_cash_custody_remaining(c.id),
        'created_at',c.created_at
      ) order by c.created_at desc)
      from public.employee_cash_custodies c
      join public.employees e on e.id=c.employee_id
      left join public.projects p on p.id=c.project_id
      join public.accounting_accounts a on a.id=c.cash_bank_account_id
    ),'[]'::jsonb),
    'settlements',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,
        'custody_id',s.custody_id,
        'expense_category',s.expense_category,
        'expense_account_id',s.expense_account_id,
        'expense_account_code',ea.account_code,
        'expense_account_name',coalesce(ea.name_ar,ea.name_en),
        'amount',s.amount,
        'settled_on',s.settled_on,
        'notes',s.notes,
        'status',s.status,
        'actual_cost_entry_id',s.actual_cost_entry_id,
        'created_at',s.created_at
      ) order by s.created_at)
      from public.employee_cash_custody_settlements s
      join public.accounting_accounts ea on ea.id=s.expense_account_id
    ),'[]'::jsonb),
    'returns',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',r.id,
        'custody_id',r.custody_id,
        'amount',r.amount,
        'returned_on',r.returned_on,
        'cash_bank_account_id',r.cash_bank_account_id,
        'cash_bank_account_code',a.account_code,
        'cash_bank_account_name',coalesce(a.name_ar,a.name_en),
        'notes',r.notes,
        'created_at',r.created_at
      ) order by r.created_at)
      from public.employee_cash_custody_returns r
      join public.accounting_accounts a on a.id=r.cash_bank_account_id
    ),'[]'::jsonb),
    'employees',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',e.id,
        'full_name',e.full_name,
        'job_title',e.job_title
      ) order by e.full_name)
      from public.employees e
      where e.status='active'
    ),'[]'::jsonb),
    'projects',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',p.id,
        'project_code',p.project_code,
        'project_name',p.project_name
      ) order by p.project_code)
      from public.projects p
      where p.lifecycle not in('closed','cancelled')
    ),'[]'::jsonb),
    'cash_bank_accounts',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.account_code)
      from public.get_cash_bank_posting_accounts() x
    ),'[]'::jsonb),
    'expense_accounts',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.account_code)
      from public.get_expense_posting_accounts() x
    ),'[]'::jsonb)
  ) into result;

  return result;
end
$$;
revoke all on function public.get_employee_cash_custody_workspace() from public,anon;
grant execute on function public.get_employee_cash_custody_workspace() to authenticated;

commit;