alter table public.expenses
  add column if not exists tax_rate numeric(9,4) not null default 0;

alter table public.expenses
  add column if not exists tax_amount numeric(18,2) not null default 0;

alter table public.expenses
  add column if not exists net_amount numeric(18,2)
    generated always as (round(amount-coalesce(tax_amount,0),2)) stored;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='expenses_tax_rate_valid'
      and conrelid='public.expenses'::regclass
  ) then
    alter table public.expenses
      add constraint expenses_tax_rate_valid
      check (tax_rate>=0 and tax_rate<=100) not valid;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conname='expenses_tax_amount_valid'
      and conrelid='public.expenses'::regclass
  ) then
    alter table public.expenses
      add constraint expenses_tax_amount_valid
      check (
        tax_amount>=0
        and net_amount>0
        and tax_amount=round(net_amount*tax_rate/100,2)
      ) not valid;
  end if;
end
$$;

create or replace function public.post_expense_with_tax(
  expense_category text,
  expense_net_amount numeric,
  expense_tax_rate numeric default 0,
  spent_on date default current_date,
  expense_notes text default null,
  target_project uuid default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  saved public.expenses%rowtype;
  tax_rate_value numeric:=coalesce(expense_tax_rate,0);
  net_value numeric(18,2);
  tax_value numeric(18,2);
  gross_value numeric(18,2);
begin
  if not private.commercial_page_allowed('expenses') then
    raise exception using errcode='42501',message='Expense access required';
  end if;
  if nullif(btrim(expense_category),'') is null then
    raise exception using errcode='22023',message='Expense category is required';
  end if;
  if expense_net_amount is null
     or expense_net_amount<=0
     or expense_net_amount='NaN'::numeric then
    raise exception using errcode='22023',message='Expense net amount must be positive';
  end if;
  if tax_rate_value='NaN'::numeric
     or tax_rate_value<0
     or tax_rate_value>100 then
    raise exception using errcode='22023',message='Expense tax rate must be between 0 and 100';
  end if;
  if command_id is null then
    raise exception using errcode='22023',message='Command id is required';
  end if;

  select * into saved
  from public.expenses
  where expenses.command_id=post_expense_with_tax.command_id;
  if found then return to_jsonb(saved); end if;

  if target_project is not null then
    perform 1
    from public.projects
    where id=target_project and lifecycle not in ('closed','cancelled')
    for update;
    if not found then
      raise exception using errcode='23503',
        message='An active project is required for a project expense';
    end if;
  end if;

  net_value:=round(expense_net_amount,2);
  tax_value:=round(net_value*tax_rate_value/100,2);
  gross_value:=round(net_value+tax_value,2);

  insert into public.expenses(
    category,amount,tax_rate,tax_amount,expense_date,notes,
    project_id,created_by,command_id
  )
  values(
    btrim(expense_category),gross_value,tax_rate_value,tax_value,
    coalesce(spent_on,current_date),nullif(btrim(expense_notes),''),
    target_project,auth.uid(),command_id
  )
  returning * into saved;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,new_data,metadata
  )
  values(
    'expenses',saved.id::text,'expense_posted',auth.uid(),to_jsonb(saved),
    jsonb_build_object(
      'project_id',target_project,
      'net_amount',net_value,
      'tax_rate',tax_rate_value,
      'tax_amount',tax_value,
      'gross_amount',gross_value
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.post_expense_with_tax(text,numeric,numeric,date,text,uuid,uuid)
  from public,anon;
grant execute on function public.post_expense_with_tax(text,numeric,numeric,date,text,uuid,uuid)
  to authenticated;

create or replace function public.post_expense(
  expense_category text,
  expense_amount numeric,
  spent_on date default current_date,
  expense_notes text default null,
  target_project uuid default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  return public.post_expense_with_tax(
    expense_category,expense_amount,0,spent_on,
    expense_notes,target_project,command_id
  );
end
$$;

revoke all on function public.post_expense(text,numeric,date,text,uuid,uuid)
  from public,anon;
grant execute on function public.post_expense(text,numeric,date,text,uuid,uuid)
  to authenticated;

create or replace function private.accounting_expense_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.created_by,new.cancelled_by);
  event_date date:=coalesce(new.expense_date,current_date);
  expense_account uuid;
  vat_account uuid;
  bank_account uuid;
  net_base numeric(18,2);
  tax_base numeric(18,2);
  gross_base numeric(18,2);
  reference_value text;
  lines jsonb:='[]'::jsonb;
begin
  if tg_op='INSERT' then
    if new.cancelled_at is not null then return new; end if;
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;

    gross_base:=round(coalesce(new.amount,0),2);
    tax_base:=round(coalesce(new.tax_amount,0),2);
    net_base:=round(gross_base-tax_base,2);

    if gross_base<=0 or net_base<=0 or tax_base<0
       or gross_base<>round(net_base+tax_base,2) then
      raise exception using errcode='23514',
        message='Expense net, tax and gross amounts are inconsistent';
    end if;

    expense_account:=private.accounting_resolve_mapping('expense_default','global','');
    bank_account:=private.accounting_resolve_mapping('default_cash_bank','global','');
    reference_value:='expense:'||new.id::text;

    lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',expense_account,'debit',net_base,'credit',0,
        'description',new.category,'project_id',new.project_id,
        'source_line_id','expense','reference',reference_value
      )
    );

    if tax_base>0 then
      vat_account:=private.accounting_resolve_mapping('vat_input','global','');
      lines:=lines||jsonb_build_array(
        jsonb_build_object(
          'account_id',vat_account,'debit',tax_base,'credit',0,
          'description','ضريبة قيمة مضافة مدخلات',
          'project_id',new.project_id,'source_line_id','vat_input',
          'reference',reference_value
        )
      );
    end if;

    lines:=lines||jsonb_build_array(
      jsonb_build_object(
        'account_id',bank_account,'debit',0,'credit',gross_base,
        'description','سداد مصروف','project_id',new.project_id,
        'source_line_id','cash_bank','reference',reference_value
      )
    );

    perform private.accounting_post_source_journal(
      'expenses','expense_posted',new.id::text,event_date,
      'مصروف — '||new.category,reference_value,new.project_id,lines,actor
    );

    return new;
  end if;

  if tg_op='UPDATE'
     and old.cancelled_at is null
     and new.cancelled_at is not null then
    perform private.accounting_reverse_source_journal(
      'expenses','expense_posted',new.id::text,
      coalesce(new.cancelled_at::date,current_date),
      coalesce(nullif(btrim(new.cancellation_reason),''),'إلغاء المصروف'),
      coalesce(auth.uid(),new.cancelled_by)
    );
    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_expense_gl_trigger()
  from public,anon,authenticated;

create or replace function private.guard_expense_financial_history()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='23514',
      message='Expense history cannot be deleted; use cancel_expense';
  end if;

  if old.cancelled_at is not null and new is distinct from old then
    raise exception using errcode='23514',message='Cancelled expense is immutable';
  end if;

  if old.actual_cost_entry_id is not null and (
    new.project_id is distinct from old.project_id
    or new.amount is distinct from old.amount
    or new.tax_rate is distinct from old.tax_rate
    or new.tax_amount is distinct from old.tax_amount
    or new.expense_date is distinct from old.expense_date
    or new.category is distinct from old.category
  ) then
    raise exception using errcode='23514',
      message='Posted expense financial fields are immutable; reverse it first';
  end if;

  return new;
end
$$;

revoke all on function private.guard_expense_financial_history()
  from public,anon,authenticated;
