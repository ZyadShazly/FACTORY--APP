-- Allow each expense to choose its actual Cash/Bank settlement account.
-- Existing callers remain backward compatible through NULL -> default_cash_bank fallback.

begin;

alter table public.expenses
  add column if not exists cash_bank_account_id uuid
  references public.accounting_accounts(id) on delete restrict;

create index if not exists expenses_cash_bank_account_idx
  on public.expenses(cash_bank_account_id)
  where cash_bank_account_id is not null;

drop function if exists public.post_expense_with_tax(text,numeric,numeric,date,text,uuid,uuid);

create function public.post_expense_with_tax(
  expense_category text,
  expense_net_amount numeric,
  expense_tax_rate numeric default 0,
  spent_on date default current_date,
  expense_notes text default null,
  target_project uuid default null,
  command_id uuid default gen_random_uuid(),
  cash_bank_account uuid default null
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

  if cash_bank_account is not null then
    perform private.accounting_assert_cash_bank_posting_account(cash_bank_account);
  end if;

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
    project_id,created_by,command_id,cash_bank_account_id
  )
  values(
    btrim(expense_category),gross_value,tax_rate_value,tax_value,
    coalesce(spent_on,current_date),nullif(btrim(expense_notes),''),
    target_project,auth.uid(),command_id,cash_bank_account
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
      'gross_amount',gross_value,
      'cash_bank_account_id',cash_bank_account
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.post_expense_with_tax(text,numeric,numeric,date,text,uuid,uuid,uuid)
  from public,anon;
grant execute on function public.post_expense_with_tax(text,numeric,numeric,date,text,uuid,uuid,uuid)
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
    bank_account:=case
      when new.cash_bank_account_id is null
        then private.accounting_resolve_mapping('default_cash_bank','global','')
      else private.accounting_assert_cash_bank_posting_account(new.cash_bank_account_id)
    end;
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

comment on column public.expenses.cash_bank_account_id is
  'User-selected active posting Cash/Bank GL account used for this expense; NULL preserves legacy default mapping behavior.';

commit;
