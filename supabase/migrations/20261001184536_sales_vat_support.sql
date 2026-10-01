-- Sales VAT support for configurable customer-facing VAT rates.
-- Additive and backward compatible: existing post_sale callers remain tax-free (0%),
-- while the UI uses post_sale_with_tax for explicit rates.

begin;

alter table public.sales
  add column if not exists subtotal numeric(18,2)
    generated always as (round(qty * unit_price, 2)) stored;

alter table public.sales
  add column if not exists tax_rate numeric(9,4) not null default 0;

alter table public.sales
  add column if not exists tax_amount numeric(18,2) not null default 0;

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='sales_tax_rate_valid'
      and conrelid='public.sales'::regclass
  ) then
    alter table public.sales
      add constraint sales_tax_rate_valid
      check (tax_rate >= 0 and tax_rate <= 100) not valid;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conname='sales_tax_amount_consistent'
      and conrelid='public.sales'::regclass
  ) then
    alter table public.sales
      add constraint sales_tax_amount_consistent
      check (tax_amount = round((qty * unit_price) * tax_rate / 100, 2)) not valid;
  end if;

  if not exists(
    select 1 from pg_constraint
    where conname='sales_total_tax_consistent'
      and conrelid='public.sales'::regclass
  ) then
    alter table public.sales
      add constraint sales_total_tax_consistent
      check (total = round((qty * unit_price) + tax_amount, 2)) not valid;
  end if;
end
$$;

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,
  suggested_account_code,description,required_for_auto_posting,is_active,sort_order
)
select
  'vat_output',
  'ضريبة قيمة مضافة مخرجات',
  'VAT Output',
  'sales',
  array['liability']::text[],
  '2.1.07',
  'ضريبة القيمة المضافة المستحقة على المبيعات.',
  true,
  true,
  45
where not exists(
  select 1 from public.accounting_mapping_definitions
  where mapping_key='vat_output'
);

insert into public.accounting_account_mappings(
  mapping_key,scope_type,scope_value,account_id,is_active
)
select 'vat_output','global','',a.id,true
from public.accounting_accounts a
where a.account_code='2.1.07'
  and a.is_posting
  and a.is_active
  and not exists(
    select 1
    from public.accounting_account_mappings m
    where m.mapping_key='vat_output'
      and m.scope_type='global'
      and m.scope_value=''
      and m.is_active
  );

create or replace function public.post_sale_with_tax(
  target_product uuid,
  target_customer uuid,
  sale_quantity numeric,
  sale_unit_price numeric,
  sale_tax_rate numeric default 0,
  sold_on date default current_date,
  sale_note text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  saved public.sales%rowtype;
  output_item uuid;
  available numeric:=0;
  remaining numeric:=sale_quantity;
  issued numeric;
  average_cost numeric;
  balance_row record;
  tax_rate_value numeric:=coalesce(sale_tax_rate,0);
  net_total numeric(18,2);
  tax_value numeric(18,2);
  gross_total numeric(18,2);
begin
  if not private.commercial_page_allowed('sales') then
    raise exception using errcode='42501',message='Sales access required';
  end if;
  if sale_quantity is null or sale_quantity<=0 or sale_quantity='NaN'::numeric then
    raise exception using errcode='22023',message='Sale quantity must be positive';
  end if;
  if sale_unit_price is null or sale_unit_price<=0 or sale_unit_price='NaN'::numeric then
    raise exception using errcode='22023',message='Sale unit price must be positive';
  end if;
  if tax_rate_value='NaN'::numeric or tax_rate_value<0 or tax_rate_value>100 then
    raise exception using errcode='22023',message='Sale tax rate must be between 0 and 100';
  end if;
  if command_id is null then
    raise exception using errcode='22023',message='Command id is required';
  end if;

  select * into saved
  from public.sales
  where sales.command_id=post_sale_with_tax.command_id;
  if found then
    return to_jsonb(saved);
  end if;

  perform 1
  from public.products
  where id=target_product and archived_at is null
  for update;
  if not found then
    raise exception using errcode='23503',message='Active product required';
  end if;

  perform 1
  from public.customers
  where id=target_customer and archived_at is null
  for update;
  if not found then
    raise exception using errcode='23503',message='Active customer required';
  end if;

  select id into output_item
  from public.inventory_items
  where product_id=target_product
    and active
    and item_type='finished_good'
  for update;

  if output_item is null then
    raise exception using errcode='23503',message='Finished-goods inventory item is not linked to this product';
  end if;

  for balance_row in
    select b.warehouse_id,b.quantity_on_hand,b.inventory_value
    from public.inventory_balances b
    where b.inventory_item_id=output_item
      and b.quantity_on_hand>0
    order by b.warehouse_id
    for update
  loop
    available:=available+balance_row.quantity_on_hand;
  end loop;

  if available<sale_quantity then
    raise exception using
      errcode='23514',
      message=format('Insufficient finished-goods inventory: %s available',available);
  end if;

  net_total:=round(sale_quantity*sale_unit_price,2);
  tax_value:=round(net_total*tax_rate_value/100,2);
  gross_total:=round(net_total+tax_value,2);

  insert into public.sales(
    product_id,customer_id,qty,unit_price,total,tax_rate,tax_amount,
    sale_date,note,status,command_id
  )
  values(
    target_product,target_customer,sale_quantity,sale_unit_price,gross_total,
    tax_rate_value,tax_value,coalesce(sold_on,current_date),
    nullif(btrim(sale_note),''),'posted',command_id
  )
  returning * into saved;

  for balance_row in
    select b.warehouse_id,b.quantity_on_hand,b.inventory_value
    from public.inventory_balances b
    where b.inventory_item_id=output_item
      and b.quantity_on_hand>0
    order by b.warehouse_id
  loop
    exit when remaining<=0;
    issued:=least(remaining,balance_row.quantity_on_hand);
    average_cost:=round(balance_row.inventory_value/nullif(balance_row.quantity_on_hand,0),4);

    insert into public.inventory_movements(
      movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,
      sale_id,reason,posted_by,metadata
    )
    values(
      'sale_issue',output_item,balance_row.warehouse_id,-issued,average_cost,
      saved.id,'صرف منتج تام للبيع',actor,
      jsonb_build_object(
        'source','sale_posting',
        'sale_id',saved.id,
        'product_id',target_product,
        'tax_rate',tax_rate_value,
        'tax_amount',tax_value
      )
    );

    remaining:=remaining-issued;
  end loop;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,new_data,metadata
  )
  values(
    'sales',saved.id::text,'sale_posted',actor,to_jsonb(saved),
    jsonb_build_object(
      'inventory_item_id',output_item,
      'quantity',sale_quantity,
      'subtotal',net_total,
      'tax_rate',tax_rate_value,
      'tax_amount',tax_value,
      'total',gross_total
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.post_sale_with_tax(uuid,uuid,numeric,numeric,numeric,date,text,uuid)
  from public,anon;
grant execute on function public.post_sale_with_tax(uuid,uuid,numeric,numeric,numeric,date,text,uuid)
  to authenticated;

create or replace function public.post_sale(
  target_product uuid,
  target_customer uuid,
  sale_quantity numeric,
  sale_unit_price numeric,
  sold_on date default current_date,
  sale_note text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  return public.post_sale_with_tax(
    target_product,
    target_customer,
    sale_quantity,
    sale_unit_price,
    0,
    sold_on,
    sale_note,
    command_id
  );
end
$$;

revoke all on function public.post_sale(uuid,uuid,numeric,numeric,date,text,uuid)
  from public,anon;
grant execute on function public.post_sale(uuid,uuid,numeric,numeric,date,text,uuid)
  to authenticated;

create or replace function private.accounting_sale_charge_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.cancelled_by);
  event_date date:=coalesce(new.sale_date,current_date);
  ar_account uuid;
  revenue_account uuid;
  vat_account uuid;
  gross_amount numeric(18,2);
  revenue_amount numeric(18,2);
  tax_amount_value numeric(18,2);
  lines jsonb:='[]'::jsonb;
begin
  if tg_op='INSERT' and new.status='posted' then
    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    gross_amount:=round(coalesce(new.total,0),2);
    tax_amount_value:=round(coalesce(new.tax_amount,0),2);
    revenue_amount:=round(gross_amount-tax_amount_value,2);

    if gross_amount<=0 then
      raise exception using
        errcode='23514',
        message='Positive posted sale total is required for accounting posting';
    end if;
    if tax_amount_value<0 or revenue_amount<0
       or gross_amount<>round(revenue_amount+tax_amount_value,2) then
      raise exception using
        errcode='23514',
        message='Sale net, tax, and gross totals are inconsistent';
    end if;

    ar_account:=private.accounting_resolve_mapping('accounts_receivable','global','');
    revenue_account:=private.accounting_resolve_mapping('sales_revenue','global','');

    lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',ar_account,
        'debit',gross_amount,
        'credit',0,
        'description','ذمة عميل عن بيع',
        'partner_type','customer',
        'partner_id',new.customer_id,
        'source_line_id','accounts_receivable',
        'reference','sale:'||new.id::text
      ),
      jsonb_build_object(
        'account_id',revenue_account,
        'debit',0,
        'credit',revenue_amount,
        'description','إيراد مبيعات',
        'source_line_id','sales_revenue',
        'reference','sale:'||new.id::text
      )
    );

    if tax_amount_value>0 then
      vat_account:=private.accounting_resolve_mapping('vat_output','global','');
      lines:=lines||jsonb_build_array(
        jsonb_build_object(
          'account_id',vat_account,
          'debit',0,
          'credit',tax_amount_value,
          'description','ضريبة قيمة مضافة مخرجات',
          'source_line_id','vat_output',
          'reference','sale:'||new.id::text
        )
      );
    end if;

    perform private.accounting_post_source_journal(
      'sales',
      'sale_customer_charge_posted',
      new.id::text,
      event_date,
      'إثبات مبيعات — '||new.id::text,
      'sale:'||new.id::text,
      null,
      lines,
      actor
    );

    return new;
  end if;

  if tg_op='UPDATE'
     and old.status='posted'
     and new.status='cancelled'
     and old.status is distinct from new.status then

    perform private.accounting_reverse_source_journal(
      'sales',
      'sale_customer_charge_posted',
      new.id::text,
      coalesce(new.cancelled_at::date,current_date),
      coalesce(nullif(btrim(new.cancellation_reason),''),'إلغاء البيع'),
      actor
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_sale_charge_gl_trigger()
  from public,anon,authenticated;

commit;
