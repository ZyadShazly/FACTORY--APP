-- User-selectable cash/bank accounts for supplier payments and customer receipts.
-- Keeps legacy callers compatible: when no account is provided, accounting falls back
-- to the existing default_cash_bank mapping.

begin;

alter table public.supplier_payments
  add column if not exists cash_bank_account_id uuid references public.accounting_accounts(id) on delete restrict;

alter table public.customer_receipts
  add column if not exists cash_bank_account_id uuid references public.accounting_accounts(id) on delete restrict;

create index if not exists supplier_payments_cash_bank_account_idx
  on public.supplier_payments(cash_bank_account_id)
  where cash_bank_account_id is not null;

create index if not exists customer_receipts_cash_bank_account_idx
  on public.customer_receipts(cash_bank_account_id)
  where cash_bank_account_id is not null;

create or replace function private.accounting_assert_cash_bank_posting_account(target_account uuid)
returns uuid
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  allowed boolean:=false;
begin
  if target_account is null then
    raise exception using errcode='22023',message='Cash/bank account is required';
  end if;

  with recursive cash_bank_tree as (
    select a.id,a.parent_id,a.account_code,a.account_type,a.is_posting,a.is_active
    from public.accounting_accounts a
    where a.account_code in ('1.1.01','1.1.02')
    union all
    select child.id,child.parent_id,child.account_code,child.account_type,child.is_posting,child.is_active
    from public.accounting_accounts child
    join cash_bank_tree parent on child.parent_id=parent.id
  )
  select exists(
    select 1
    from cash_bank_tree a
    where a.id=target_account
      and a.is_active
      and a.is_posting
      and a.account_type='asset'
  ) into allowed;

  if not allowed then
    raise exception using
      errcode='23514',
      message='Selected settlement account must be an active posting Cash/Bank account';
  end if;

  return target_account;
end
$$;

revoke all on function private.accounting_assert_cash_bank_posting_account(uuid)
  from public,anon,authenticated;

create or replace function public.get_cash_bank_posting_accounts()
returns table(
  id uuid,
  account_code text,
  name_ar text,
  name_en text,
  root_code text
)
language sql
stable
security definer
set search_path=''
as $$
  with recursive cash_bank_tree as (
    select a.id,a.parent_id,a.account_code,a.name_ar,a.name_en,a.account_type,a.is_posting,a.is_active,a.account_code as root_code
    from public.accounting_accounts a
    where a.account_code in ('1.1.01','1.1.02')
    union all
    select child.id,child.parent_id,child.account_code,child.name_ar,child.name_en,child.account_type,child.is_posting,child.is_active,parent.root_code
    from public.accounting_accounts child
    join cash_bank_tree parent on child.parent_id=parent.id
  )
  select a.id,a.account_code,a.name_ar,a.name_en,a.root_code
  from cash_bank_tree a
  where a.is_active
    and a.is_posting
    and a.account_type='asset'
    and private.commercial_payment_allowed()
  order by a.root_code,a.account_code
$$;

revoke all on function public.get_cash_bank_posting_accounts() from public,anon;
grant execute on function public.get_cash_bank_posting_accounts() to authenticated;

drop function if exists public.record_customer_receipt(uuid,numeric,date,text,uuid);

create function public.record_customer_receipt(
  target_customer uuid,
  receipt_amount numeric,
  received_on date,
  receipt_note text default null,
  command_id uuid default gen_random_uuid(),
  cash_bank_account uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  due numeric;
  settled numeric;
  advanced numeric;
  class text;
  saved public.customer_receipts%rowtype;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if receipt_amount is null or receipt_amount<=0 or receipt_amount='NaN'::numeric then
    raise exception using errcode='22023',message='Receipt amount must be positive';
  end if;

  select * into saved
  from public.customer_receipts
  where customer_receipts.command_id=record_customer_receipt.command_id;
  if found then return to_jsonb(saved); end if;

  if cash_bank_account is not null then
    perform private.accounting_assert_cash_bank_posting_account(cash_bank_account);
  end if;

  perform 1 from public.customers
  where id=target_customer and archived_at is null
  for update;
  if not found then
    raise exception using errcode='23503',message='Active customer required';
  end if;

  due:=private.customer_due(target_customer);
  settled:=least(receipt_amount,due);
  advanced:=receipt_amount-settled;
  class:=case when settled=0 then 'advance' when advanced=0 then 'settlement' else 'mixed' end;

  perform set_config('app.commercial_advance_rpc','on',true);

  insert into public.customer_receipts(
    customer_id,amount,receipt_date,note,transaction_classification,
    settlement_amount,advance_amount,command_id,status,cash_bank_account_id
  )
  values(
    target_customer,receipt_amount,coalesce(received_on,current_date),
    nullif(btrim(receipt_note),''),class,settled,advanced,command_id,'posted',cash_bank_account
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'customer_receipts',saved.id::text,'customer_receipt_classified',auth.uid(),to_jsonb(saved),
    jsonb_build_object(
      'due_before',due,
      'classification',class,
      'cash_bank_account_id',cash_bank_account
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.record_customer_receipt(uuid,numeric,date,text,uuid,uuid) from public,anon;
grant execute on function public.record_customer_receipt(uuid,numeric,date,text,uuid,uuid) to authenticated;

drop function if exists public.record_supplier_payment(uuid,numeric,date,text,uuid);

create function public.record_supplier_payment(
  target_supplier uuid,
  payment_amount numeric,
  paid_on date,
  payment_note text default null,
  command_id uuid default gen_random_uuid(),
  cash_bank_account uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  due numeric;
  settled numeric;
  advanced numeric;
  class text;
  saved public.supplier_payments%rowtype;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if payment_amount is null or payment_amount<=0 or payment_amount='NaN'::numeric then
    raise exception using errcode='22023',message='Payment amount must be positive';
  end if;

  select * into saved
  from public.supplier_payments
  where supplier_payments.command_id=record_supplier_payment.command_id;
  if found then return to_jsonb(saved); end if;

  if cash_bank_account is not null then
    perform private.accounting_assert_cash_bank_posting_account(cash_bank_account);
  end if;

  perform 1 from public.suppliers
  where id=target_supplier and archived_at is null
  for update;
  if not found then
    raise exception using errcode='23503',message='Active supplier required';
  end if;

  due:=private.supplier_due(target_supplier);
  settled:=least(payment_amount,due);
  advanced:=payment_amount-settled;
  class:=case when settled=0 then 'advance' when advanced=0 then 'settlement' else 'mixed' end;

  perform set_config('app.commercial_advance_rpc','on',true);

  insert into public.supplier_payments(
    supplier_id,amount,payment_date,note,transaction_classification,
    settlement_amount,advance_amount,command_id,status,cash_bank_account_id
  )
  values(
    target_supplier,payment_amount,coalesce(paid_on,current_date),
    nullif(btrim(payment_note),''),class,settled,advanced,command_id,'posted',cash_bank_account
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'supplier_payments',saved.id::text,'supplier_payment_classified',auth.uid(),to_jsonb(saved),
    jsonb_build_object(
      'due_before',due,
      'classification',class,
      'cash_bank_account_id',cash_bank_account
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.record_supplier_payment(uuid,numeric,date,text,uuid,uuid) from public,anon;
grant execute on function public.record_supplier_payment(uuid,numeric,date,text,uuid,uuid) to authenticated;

CREATE OR REPLACE FUNCTION private.accounting_cash_source_insert_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  event_date date;
  actor uuid:=auth.uid();
  lines jsonb:='[]'::jsonb;
  bank_account uuid;
  ar_account uuid;
  ap_account uuid;
  customer_advance_account uuid;
  supplier_advance_account uuid;
  target_project uuid;
begin
  if tg_table_name='customer_receipts' then
    if new.status<>'posted' then return new; end if;
    event_date:=coalesce(new.receipt_date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;
    if new.transaction_classification is null then
      raise exception using errcode='23514',message='Classified customer receipt required for accounting auto-posting';
    end if;

    bank_account:=case when new.cash_bank_account_id is null then private.accounting_resolve_mapping('default_cash_bank','global','') else private.accounting_assert_cash_bank_posting_account(new.cash_bank_account_id) end;
    lines:=jsonb_build_array(jsonb_build_object(
      'account_id',bank_account,'debit',new.amount,'credit',0,
      'description','تحصيل عميل','source_line_id','cash'
    ));

    if coalesce(new.settlement_amount,0)>0 then
      ar_account:=private.accounting_resolve_mapping('accounts_receivable','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',ar_account,'debit',0,'credit',new.settlement_amount,
        'description','تسوية ذمة عميل','partner_type','customer','partner_id',new.customer_id,
        'source_line_id','settlement'
      ));
    end if;

    if coalesce(new.advance_amount,0)>0 then
      customer_advance_account:=private.accounting_resolve_mapping('customer_advances','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',customer_advance_account,'debit',0,'credit',new.advance_amount,
        'description','دفعة مقدمة من عميل','partner_type','customer','partner_id',new.customer_id,
        'source_line_id','advance'
      ));
    end if;

    perform private.accounting_post_source_journal(
      'customers','customer_receipt_classified',new.id::text,event_date,
      'تحصيل عميل — '||new.id::text,
      'customer_receipt:'||new.id::text,
      null,lines,actor
    );
    return new;
  end if;

  if tg_table_name='supplier_payments' then
    if new.status<>'posted' then return new; end if;
    event_date:=coalesce(new.payment_date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;
    if new.transaction_classification is null then
      raise exception using errcode='23514',message='Classified supplier payment required for accounting auto-posting';
    end if;

    lines:='[]'::jsonb;

    if coalesce(new.settlement_amount,0)>0 then
      ap_account:=private.accounting_resolve_mapping('accounts_payable','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',ap_account,'debit',new.settlement_amount,'credit',0,
        'description','تسوية ذمة مورد','partner_type','supplier','partner_id',new.supplier_id,
        'source_line_id','settlement'
      ));
    end if;

    if coalesce(new.advance_amount,0)>0 then
      supplier_advance_account:=private.accounting_resolve_mapping('supplier_advances','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',supplier_advance_account,'debit',new.advance_amount,'credit',0,
        'description','دفعة مقدمة لمورد','partner_type','supplier','partner_id',new.supplier_id,
        'source_line_id','advance'
      ));
    end if;

    bank_account:=case when new.cash_bank_account_id is null then private.accounting_resolve_mapping('default_cash_bank','global','') else private.accounting_assert_cash_bank_posting_account(new.cash_bank_account_id) end;
    lines:=lines||jsonb_build_array(jsonb_build_object(
      'account_id',bank_account,'debit',0,'credit',new.amount,
      'description','دفع لمورد','source_line_id','cash'
    ));

    perform private.accounting_post_source_journal(
      'suppliers','supplier_payment_classified',new.id::text,event_date,
      'دفع لمورد — '||new.id::text,
      'supplier_payment:'||new.id::text,
      null,lines,actor
    );
    return new;
  end if;

  if tg_table_name='customer_advance_allocations' then
    if new.status<>'allocated' then return new; end if;
    event_date:=coalesce(new.allocated_at::date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;

    if new.target_type='project' then
      target_project:=new.target_id;
    else
      target_project:=null;
    end if;

    customer_advance_account:=private.accounting_resolve_mapping('customer_advances','global','');
    ar_account:=private.accounting_resolve_mapping('accounts_receivable','global','');

    lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',customer_advance_account,'debit',new.amount,'credit',0,
        'description','تخصيص دفعة مقدمة من عميل','partner_type','customer','partner_id',new.customer_id,
        'project_id',target_project,'source_line_id','advance_release'
      ),
      jsonb_build_object(
        'account_id',ar_account,'debit',0,'credit',new.amount,
        'description','تسوية ذمة عميل من دفعة مقدمة','partner_type','customer','partner_id',new.customer_id,
        'project_id',target_project,'source_line_id','receivable_settlement'
      )
    );

    perform private.accounting_post_source_journal(
      'customers','customer_advance_allocated',new.id::text,event_date,
      'تخصيص دفعة مقدمة من عميل — '||new.id::text,
      new.target_type||':'||new.target_id::text,
      target_project,lines,actor
    );
    return new;
  end if;

  if tg_table_name='supplier_advance_allocations' then
    if new.status<>'allocated' then return new; end if;
    event_date:=coalesce(new.allocated_at::date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;

    if new.target_type='supplier_invoice' then
      select si.project_id into target_project
      from public.supplier_invoices si where si.id=new.target_id;
    elsif new.target_type='material_purchase' then
      select mp.project_id into target_project
      from public.material_purchases mp where mp.id=new.target_id;
    end if;

    ap_account:=private.accounting_resolve_mapping('accounts_payable','global','');
    supplier_advance_account:=private.accounting_resolve_mapping('supplier_advances','global','');

    lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',ap_account,'debit',new.amount,'credit',0,
        'description','تسوية ذمة مورد من دفعة مقدمة','partner_type','supplier','partner_id',new.supplier_id,
        'project_id',target_project,'source_line_id','payable_settlement'
      ),
      jsonb_build_object(
        'account_id',supplier_advance_account,'debit',0,'credit',new.amount,
        'description','تخصيص دفعة مقدمة لمورد','partner_type','supplier','partner_id',new.supplier_id,
        'project_id',target_project,'source_line_id','advance_release'
      )
    );

    perform private.accounting_post_source_journal(
      'suppliers','supplier_advance_allocated',new.id::text,event_date,
      'تخصيص دفعة مقدمة لمورد — '||new.id::text,
      new.target_type||':'||new.target_id::text,
      target_project,lines,actor
    );
    return new;
  end if;

  return new;
end
$function$
;

revoke all on function private.accounting_cash_source_insert_trigger()
  from public,anon,authenticated;

comment on column public.supplier_payments.cash_bank_account_id is
  'User-selected active posting Cash/Bank GL account used for this supplier payment; NULL preserves legacy default mapping behavior.';

comment on column public.customer_receipts.cash_bank_account_id is
  'User-selected active posting Cash/Bank GL account used for this customer receipt; NULL preserves legacy default mapping behavior.';

commit;
