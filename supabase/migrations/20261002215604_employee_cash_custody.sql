-- Employee cash custody: advance -> approved expense settlement -> cash/bank return.
-- This implements the previously documented employee_cash_custody_settlement_line contract.

begin;

create sequence if not exists public.employee_cash_custody_number_seq start 1;

create table if not exists public.employee_cash_custodies(
  id uuid primary key default gen_random_uuid(),
  custody_number text not null unique,
  employee_id uuid not null references public.employees(id) on delete restrict,
  project_id uuid references public.projects(id) on delete restrict,
  issued_amount numeric(18,2) not null check(issued_amount>0),
  issued_on date not null default current_date,
  cash_bank_account_id uuid not null references public.accounting_accounts(id) on delete restrict,
  notes text,
  status text not null default 'open' check(status in('open','partially_settled','settled')),
  command_id uuid not null unique,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.employee_cash_custody_settlements(
  id uuid primary key default gen_random_uuid(),
  custody_id uuid not null references public.employee_cash_custodies(id) on delete restrict,
  expense_category text not null check(btrim(expense_category)<>''),
  amount numeric(18,2) not null check(amount>0),
  settled_on date not null default current_date,
  notes text,
  status text not null default 'approved' check(status='approved'),
  actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete restrict,
  command_id uuid not null unique,
  approved_by uuid references public.profiles(id),
  approved_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.employee_cash_custody_returns(
  id uuid primary key default gen_random_uuid(),
  custody_id uuid not null references public.employee_cash_custodies(id) on delete restrict,
  amount numeric(18,2) not null check(amount>0),
  returned_on date not null default current_date,
  cash_bank_account_id uuid not null references public.accounting_accounts(id) on delete restrict,
  notes text,
  command_id uuid not null unique,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index if not exists employee_cash_custodies_employee_idx on public.employee_cash_custodies(employee_id,created_at desc);
create index if not exists employee_cash_custodies_project_idx on public.employee_cash_custodies(project_id) where project_id is not null;
create index if not exists employee_cash_custody_settlements_custody_idx on public.employee_cash_custody_settlements(custody_id,created_at);
create index if not exists employee_cash_custody_returns_custody_idx on public.employee_cash_custody_returns(custody_id,created_at);

alter table public.employee_cash_custodies enable row level security;
alter table public.employee_cash_custody_settlements enable row level security;
alter table public.employee_cash_custody_returns enable row level security;

revoke all on public.employee_cash_custodies,public.employee_cash_custody_settlements,public.employee_cash_custody_returns from public,anon,authenticated;

create or replace function private.employee_cash_custody_remaining(target_custody uuid)
returns numeric
language sql
stable
security definer
set search_path=''
as $$
  select round(c.issued_amount
    -coalesce((select sum(s.amount) from public.employee_cash_custody_settlements s where s.custody_id=c.id and s.status='approved'),0)
    -coalesce((select sum(r.amount) from public.employee_cash_custody_returns r where r.custody_id=c.id),0),2)
  from public.employee_cash_custodies c
  where c.id=target_custody
$$;
revoke all on function private.employee_cash_custody_remaining(uuid) from public,anon,authenticated;

create or replace function private.refresh_employee_cash_custody_status(target_custody uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare remaining numeric; activity_count integer;
begin
  remaining:=private.employee_cash_custody_remaining(target_custody);
  if remaining is null then raise exception using errcode='P0002',message='Cash custody was not found'; end if;
  if remaining<0 then raise exception using errcode='23514',message='Cash custody cannot be over-settled'; end if;
  select
    (select count(*) from public.employee_cash_custody_settlements where custody_id=target_custody)
    +(select count(*) from public.employee_cash_custody_returns where custody_id=target_custody)
  into activity_count;
  update public.employee_cash_custodies
  set status=case when remaining=0 then 'settled' when activity_count>0 then 'partially_settled' else 'open' end,
      updated_at=now()
  where id=target_custody;
end
$$;
revoke all on function private.refresh_employee_cash_custody_status(uuid) from public,anon,authenticated;

create or replace function public.record_employee_cash_custody(
  target_employee uuid,
  advance_amount numeric,
  issued_on date default current_date,
  cash_bank_account uuid default null,
  target_project uuid default null,
  custody_notes text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare saved public.employee_cash_custodies%rowtype; custody_ref text;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if advance_amount is null or advance_amount<=0 then
    raise exception using errcode='22023',message='Custody advance amount must be positive';
  end if;
  if cash_bank_account is null then
    raise exception using errcode='22023',message='Cash or bank account is required';
  end if;
  if command_id is null then
    raise exception using errcode='22023',message='Command id is required';
  end if;

  select * into saved from public.employee_cash_custodies where employee_cash_custodies.command_id=record_employee_cash_custody.command_id;
  if found then return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(saved.id)); end if;

  perform 1 from public.employees where id=target_employee and status='active';
  if not found then raise exception using errcode='23503',message='Active employee required'; end if;

  if target_project is not null then
    perform 1 from public.projects where id=target_project and lifecycle not in('closed','cancelled');
    if not found then raise exception using errcode='23503',message='Active project required'; end if;
  end if;

  perform private.accounting_assert_cash_bank_posting_account(cash_bank_account);
  custody_ref:='CST-'||to_char(coalesce(issued_on,current_date),'YYYY')||'-'||lpad(nextval('public.employee_cash_custody_number_seq')::text,6,'0');

  insert into public.employee_cash_custodies(
    custody_number,employee_id,project_id,issued_amount,issued_on,cash_bank_account_id,notes,command_id,created_by
  ) values(
    custody_ref,target_employee,target_project,round(advance_amount,2),coalesce(issued_on,current_date),cash_bank_account,
    nullif(btrim(custody_notes),''),command_id,auth.uid()
  ) returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('employee_cash_custodies',saved.id::text,'employee_cash_custody_issued',auth.uid(),to_jsonb(saved),
    jsonb_build_object('custody_number',saved.custody_number,'employee_id',saved.employee_id,'project_id',saved.project_id));

  return to_jsonb(saved)||jsonb_build_object('remaining_amount',saved.issued_amount);
end
$$;
revoke all on function public.record_employee_cash_custody(uuid,numeric,date,uuid,uuid,text,uuid) from public,anon;
grant execute on function public.record_employee_cash_custody(uuid,numeric,date,uuid,uuid,text,uuid) to authenticated;

create or replace function public.record_employee_cash_custody_settlement(
  target_custody uuid,
  expense_amount numeric,
  expense_category text,
  settled_on date default current_date,
  expense_notes text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare custody public.employee_cash_custodies%rowtype; saved public.employee_cash_custody_settlements%rowtype;
  remaining numeric; actual_entry jsonb; actor uuid:=auth.uid();
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
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.employee_cash_custody_settlements
  where employee_cash_custody_settlements.command_id=record_employee_cash_custody_settlement.command_id;
  if found then return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(saved.custody_id)); end if;

  select * into custody from public.employee_cash_custodies where id=target_custody for update;
  if not found then raise exception using errcode='P0002',message='Cash custody was not found'; end if;
  if custody.status='settled' then raise exception using errcode='23514',message='Cash custody is already settled'; end if;

  remaining:=private.employee_cash_custody_remaining(custody.id);
  if round(expense_amount,2)>remaining then
    raise exception using errcode='23514',message='Settlement exceeds remaining cash custody balance';
  end if;

  insert into public.employee_cash_custody_settlements(
    custody_id,expense_category,amount,settled_on,notes,command_id,approved_by,created_by
  ) values(
    custody.id,btrim(expense_category),round(expense_amount,2),coalesce(settled_on,current_date),
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
      'quantity',1,'unit','تسوية','unit_cost',saved.amount,'cost_date',saved.settled_on,
      'metadata',jsonb_build_object('custody_id',custody.id,'employee_id',custody.employee_id)
    ));
    perform public.submit_project_actual_cost((actual_entry->>'id')::uuid);
    perform public.approve_project_actual_cost((actual_entry->>'id')::uuid);
    update public.employee_cash_custody_settlements set actual_cost_entry_id=(actual_entry->>'id')::uuid where id=saved.id returning * into saved;
  end if;

  perform private.refresh_employee_cash_custody_status(custody.id);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('employee_cash_custody_settlements',saved.id::text,'employee_cash_custody_settlement_approved',actor,to_jsonb(saved),
    jsonb_build_object('custody_id',custody.id,'remaining_amount',private.employee_cash_custody_remaining(custody.id)));

  return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(custody.id));
end
$$;
revoke all on function public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid) from public,anon;
grant execute on function public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid) to authenticated;

create or replace function public.record_employee_cash_custody_return(
  target_custody uuid,
  return_amount numeric,
  returned_on date default current_date,
  cash_bank_account uuid default null,
  return_notes text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare custody public.employee_cash_custodies%rowtype; saved public.employee_cash_custody_returns%rowtype; remaining numeric;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if return_amount is null or return_amount<=0 then
    raise exception using errcode='22023',message='Return amount must be positive';
  end if;
  if cash_bank_account is null then
    raise exception using errcode='22023',message='Cash or bank account is required';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.employee_cash_custody_returns
  where employee_cash_custody_returns.command_id=record_employee_cash_custody_return.command_id;
  if found then return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(saved.custody_id)); end if;

  select * into custody from public.employee_cash_custodies where id=target_custody for update;
  if not found then raise exception using errcode='P0002',message='Cash custody was not found'; end if;
  if custody.status='settled' then raise exception using errcode='23514',message='Cash custody is already settled'; end if;

  perform private.accounting_assert_cash_bank_posting_account(cash_bank_account);
  remaining:=private.employee_cash_custody_remaining(custody.id);
  if round(return_amount,2)>remaining then
    raise exception using errcode='23514',message='Return exceeds remaining cash custody balance';
  end if;

  insert into public.employee_cash_custody_returns(
    custody_id,amount,returned_on,cash_bank_account_id,notes,command_id,created_by
  ) values(
    custody.id,round(return_amount,2),coalesce(returned_on,current_date),cash_bank_account,
    nullif(btrim(return_notes),''),command_id,auth.uid()
  ) returning * into saved;

  perform private.refresh_employee_cash_custody_status(custody.id);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('employee_cash_custody_returns',saved.id::text,'employee_cash_custody_returned',auth.uid(),to_jsonb(saved),
    jsonb_build_object('custody_id',custody.id,'remaining_amount',private.employee_cash_custody_remaining(custody.id)));

  return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(custody.id));
end
$$;
revoke all on function public.record_employee_cash_custody_return(uuid,numeric,date,uuid,text,uuid) from public,anon;
grant execute on function public.record_employee_cash_custody_return(uuid,numeric,date,uuid,text,uuid) to authenticated;

create or replace function private.accounting_employee_cash_custody_advance_gl()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare advance_account uuid; cash_account uuid; reference_value text;
begin
  if not private.accounting_source_event_in_scope(new.issued_on) then return new; end if;
  advance_account:=private.accounting_resolve_mapping('employee_advances_receivable','global','');
  cash_account:=private.accounting_assert_cash_bank_posting_account(new.cash_bank_account_id);
  reference_value:=new.custody_number;
  perform private.accounting_post_source_journal(
    'employee_cash_custody','custody_advance_posted',new.id::text,new.issued_on,
    'صرف عهدة نقدية — '||new.custody_number,reference_value,new.project_id,
    jsonb_build_array(
      jsonb_build_object('account_id',advance_account,'debit',new.issued_amount,'credit',0,'description','عهدة نقدية للموظف','partner_type','employee','partner_id',new.employee_id,'project_id',new.project_id,'source_line_id','employee_advance','reference',reference_value),
      jsonb_build_object('account_id',cash_account,'debit',0,'credit',new.issued_amount,'description','صرف عهدة نقدية','partner_type','employee','partner_id',new.employee_id,'project_id',new.project_id,'source_line_id','cash_bank','reference',reference_value)
    ),coalesce(auth.uid(),new.created_by)
  );
  return new;
end
$$;
revoke all on function private.accounting_employee_cash_custody_advance_gl() from public,anon,authenticated;

create or replace function private.accounting_employee_cash_custody_settlement_gl()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare custody public.employee_cash_custodies%rowtype; advance_account uuid; expense_account uuid; reference_value text;
begin
  select * into custody from public.employee_cash_custodies where id=new.custody_id;
  if not found then raise exception using errcode='23503',message='Cash custody was not found for settlement'; end if;
  if not private.accounting_source_event_in_scope(new.settled_on) then return new; end if;
  advance_account:=private.accounting_resolve_mapping('employee_advances_receivable','global','');
  expense_account:=private.accounting_resolve_mapping('expense_default','global','');
  reference_value:=custody.custody_number||'/SET/'||left(new.id::text,8);
  perform private.accounting_post_source_journal(
    'employee_cash_custody','custody_settlement_posted',new.id::text,new.settled_on,
    'تسوية عهدة نقدية — '||new.expense_category,reference_value,custody.project_id,
    jsonb_build_array(
      jsonb_build_object('account_id',expense_account,'debit',new.amount,'credit',0,'description',new.expense_category,'partner_type','employee','partner_id',custody.employee_id,'project_id',custody.project_id,'source_line_id','expense','reference',reference_value),
      jsonb_build_object('account_id',advance_account,'debit',0,'credit',new.amount,'description','تسوية رصيد عهدة الموظف','partner_type','employee','partner_id',custody.employee_id,'project_id',custody.project_id,'source_line_id','employee_advance','reference',reference_value)
    ),coalesce(auth.uid(),new.created_by)
  );
  return new;
end
$$;
revoke all on function private.accounting_employee_cash_custody_settlement_gl() from public,anon,authenticated;

create or replace function private.accounting_employee_cash_custody_return_gl()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare custody public.employee_cash_custodies%rowtype; advance_account uuid; cash_account uuid; reference_value text;
begin
  select * into custody from public.employee_cash_custodies where id=new.custody_id;
  if not found then raise exception using errcode='23503',message='Cash custody was not found for return'; end if;
  if not private.accounting_source_event_in_scope(new.returned_on) then return new; end if;
  advance_account:=private.accounting_resolve_mapping('employee_advances_receivable','global','');
  cash_account:=private.accounting_assert_cash_bank_posting_account(new.cash_bank_account_id);
  reference_value:=custody.custody_number||'/RET/'||left(new.id::text,8);
  perform private.accounting_post_source_journal(
    'employee_cash_custody','custody_return_posted',new.id::text,new.returned_on,
    'رد متبقي عهدة نقدية — '||custody.custody_number,reference_value,custody.project_id,
    jsonb_build_array(
      jsonb_build_object('account_id',cash_account,'debit',new.amount,'credit',0,'description','رد نقدية من الموظف','partner_type','employee','partner_id',custody.employee_id,'project_id',custody.project_id,'source_line_id','cash_bank','reference',reference_value),
      jsonb_build_object('account_id',advance_account,'debit',0,'credit',new.amount,'description','إقفال جزء من عهدة الموظف','partner_type','employee','partner_id',custody.employee_id,'project_id',custody.project_id,'source_line_id','employee_advance','reference',reference_value)
    ),coalesce(auth.uid(),new.created_by)
  );
  return new;
end
$$;
revoke all on function private.accounting_employee_cash_custody_return_gl() from public,anon,authenticated;

drop trigger if exists accounting_employee_cash_custody_advance_gl on public.employee_cash_custodies;
create trigger accounting_employee_cash_custody_advance_gl after insert on public.employee_cash_custodies
for each row execute function private.accounting_employee_cash_custody_advance_gl();

drop trigger if exists accounting_employee_cash_custody_settlement_gl on public.employee_cash_custody_settlements;
create trigger accounting_employee_cash_custody_settlement_gl after insert on public.employee_cash_custody_settlements
for each row execute function private.accounting_employee_cash_custody_settlement_gl();

drop trigger if exists accounting_employee_cash_custody_return_gl on public.employee_cash_custody_returns;
create trigger accounting_employee_cash_custody_return_gl after insert on public.employee_cash_custody_returns
for each row execute function private.accounting_employee_cash_custody_return_gl();

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
        'id',c.id,'custody_number',c.custody_number,'employee_id',c.employee_id,'employee_name',e.full_name,
        'project_id',c.project_id,'project_code',p.project_code,'project_name',p.project_name,
        'issued_amount',c.issued_amount,'issued_on',c.issued_on,'cash_bank_account_id',c.cash_bank_account_id,
        'cash_bank_account_code',a.account_code,'cash_bank_account_name',coalesce(a.name_ar,a.name_en),
        'notes',c.notes,'status',c.status,
        'settled_amount',coalesce((select sum(s.amount) from public.employee_cash_custody_settlements s where s.custody_id=c.id and s.status='approved'),0),
        'returned_amount',coalesce((select sum(r.amount) from public.employee_cash_custody_returns r where r.custody_id=c.id),0),
        'remaining_amount',private.employee_cash_custody_remaining(c.id),'created_at',c.created_at
      ) order by c.created_at desc)
      from public.employee_cash_custodies c
      join public.employees e on e.id=c.employee_id
      left join public.projects p on p.id=c.project_id
      join public.accounting_accounts a on a.id=c.cash_bank_account_id
    ),'[]'::jsonb),
    'settlements',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,'custody_id',s.custody_id,'expense_category',s.expense_category,'amount',s.amount,
        'settled_on',s.settled_on,'notes',s.notes,'status',s.status,'actual_cost_entry_id',s.actual_cost_entry_id,'created_at',s.created_at
      ) order by s.created_at)
      from public.employee_cash_custody_settlements s
    ),'[]'::jsonb),
    'returns',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',r.id,'custody_id',r.custody_id,'amount',r.amount,'returned_on',r.returned_on,
        'cash_bank_account_id',r.cash_bank_account_id,'cash_bank_account_code',a.account_code,
        'cash_bank_account_name',coalesce(a.name_ar,a.name_en),'notes',r.notes,'created_at',r.created_at
      ) order by r.created_at)
      from public.employee_cash_custody_returns r
      join public.accounting_accounts a on a.id=r.cash_bank_account_id
    ),'[]'::jsonb),
    'employees',coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'full_name',e.full_name,'job_title',e.job_title) order by e.full_name) from public.employees e where e.status='active'),'[]'::jsonb),
    'projects',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'project_code',p.project_code,'project_name',p.project_name) order by p.project_code) from public.projects p where p.lifecycle not in('closed','cancelled')),'[]'::jsonb),
    'cash_bank_accounts',coalesce((select jsonb_agg(to_jsonb(x) order by x.account_code) from public.get_cash_bank_posting_accounts() x),'[]'::jsonb)
  ) into result;
  return result;
end
$$;
revoke all on function public.get_employee_cash_custody_workspace() from public,anon;
grant execute on function public.get_employee_cash_custody_workspace() to authenticated;

commit;