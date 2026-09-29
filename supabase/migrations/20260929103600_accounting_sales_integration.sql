-- NextEP accounting integration: sales customer charge and sale inventory issue.
-- Additive source-driven GL integration. Existing historical sales are not backfilled.

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
  sale_amount numeric(18,2);
begin
  if tg_op='INSERT' and new.status='posted' then
    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    sale_amount:=round(coalesce(new.total,0),2);
    if sale_amount<=0 then
      raise exception using errcode='23514',message='Positive posted sale total is required for accounting posting';
    end if;

    ar_account:=private.accounting_resolve_mapping('accounts_receivable','global','');
    revenue_account:=private.accounting_resolve_mapping('sales_revenue','global','');

    perform private.accounting_post_source_journal(
      'sales',
      'sale_customer_charge_posted',
      new.id::text,
      event_date,
      'إثبات مبيعات — '||new.id::text,
      'sale:'||new.id::text,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',ar_account,
          'debit',sale_amount,
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
          'credit',sale_amount,
          'description','إيراد مبيعات',
          'source_line_id','sales_revenue',
          'reference','sale:'||new.id::text
        )
      ),
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

create or replace function private.accounting_sale_inventory_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.posted_by);
  source_sale public.sales%rowtype;
  event_date date;
  cogs_account uuid;
  inventory_account uuid;
  cost_amount numeric(18,2);
begin
  if new.movement_type='sale_issue'
     and new.sale_id is not null then

    select * into source_sale
    from public.sales
    where id=new.sale_id;

    if not found then
      raise exception using errcode='23503',message='Sale source was not found for inventory issue';
    end if;

    event_date:=coalesce(source_sale.sale_date,new.posted_at::date,current_date);

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    cost_amount:=round(abs(coalesce(new.quantity_delta,0))*coalesce(new.unit_cost,0),2);

    if cost_amount<0 then
      raise exception using errcode='23514',message='Negative sale inventory cost is not allowed';
    end if;

    -- A legitimately zero-valued inventory issue has no GL value to post.
    if cost_amount=0 then
      return new;
    end if;

    cogs_account:=private.accounting_resolve_mapping('cogs','global','');
    inventory_account:=private.accounting_resolve_mapping('inventory','global','');

    perform private.accounting_post_source_journal(
      'sales',
      'sale_inventory_issue_posted',
      new.id::text,
      event_date,
      'تكلفة مبيعات — '||new.id::text,
      coalesce(new.movement_number,'sale_issue:'||new.id::text),
      null,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',cogs_account,
          'debit',cost_amount,
          'credit',0,
          'description','تكلفة بضاعة مباعة',
          'source_line_id','cogs',
          'reference',coalesce(new.movement_number,'sale_issue:'||new.id::text)
        ),
        jsonb_build_object(
          'account_id',inventory_account,
          'debit',0,
          'credit',cost_amount,
          'description','خروج مخزون للبيع',
          'source_line_id','inventory',
          'reference',coalesce(new.movement_number,'sale_issue:'||new.id::text)
        )
      ),
      actor
    );

    return new;
  end if;

  if new.movement_type='sale_issue_reversal'
     and new.reversed_movement_id is not null then

    perform private.accounting_reverse_source_journal(
      'sales',
      'sale_inventory_issue_posted',
      new.reversed_movement_id::text,
      coalesce(new.posted_at::date,current_date),
      coalesce(nullif(btrim(new.reason),''),'عكس صرف مخزون مبيعات'),
      actor
    );

    return new;
  end if;

  return new;
end
$$;
revoke all on function private.accounting_sale_inventory_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_sales_charge_gl
after insert or update of status on public.sales
for each row execute function private.accounting_sale_charge_gl_trigger();

create trigger accounting_sales_inventory_gl
after insert on public.inventory_movements
for each row execute function private.accounting_sale_inventory_gl_trigger();
