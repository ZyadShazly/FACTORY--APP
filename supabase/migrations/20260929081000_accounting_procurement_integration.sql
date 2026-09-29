-- NextEP accounting integration: procurement receipts and supplier invoices.
-- Depends on the accounting source-link helpers introduced by accounting_cash_integration.
-- No historical procurement row is backfilled.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values(
  'purchase_price_variance',
  'فروقات أسعار المشتريات',
  'Purchase Price Variance',
  'procurement',
  array['expense','cost_of_sales']::text[],
  null,
  'فرق صافي قيمة فاتورة المورد عن قيمة الاستلام المسجلة على GRNI، بما في ذلك فروقات التقريب.',
  true,
  95
)
on conflict(mapping_key) do nothing;

create or replace function private.accounting_procurement_inventory_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.posted_by);
  event_date date:=coalesce(new.posted_at::date,current_date);
  source record;
  inventory_account uuid;
  grni_account uuid;
  document_amount numeric(18,4);
  base_amount numeric(18,2);
  gl_base_currency text;
  linked_journal uuid;
begin
  if new.movement_type='receipt'
     and new.goods_receipt_item_id is not null then

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    select
      gri.id as receipt_item_id,
      gr.id as receipt_id,
      gr.receipt_number,
      po.id as purchase_order_id,
      po.order_number,
      po.supplier_id,
      po.project_id,
      po.currency,
      po.base_currency,
      po.exchange_rate,
      poi.description,
      poi.cost_center_reference
    into source
    from public.goods_receipt_items gri
    join public.goods_receipts gr on gr.id=gri.goods_receipt_id
    join public.purchase_order_items poi on poi.id=gri.purchase_order_item_id
    join public.purchase_orders po on po.id=poi.purchase_order_id
    where gri.id=new.goods_receipt_item_id;

    if not found then
      raise exception using errcode='23503',message='Procurement receipt source was not found for inventory movement';
    end if;

    select s.base_currency into gl_base_currency
    from public.accounting_settings s
    where s.id=true;

    if source.base_currency is null
       or upper(source.base_currency)<>upper(gl_base_currency)
       or source.exchange_rate is null
       or source.exchange_rate<=0 then
      raise exception using
        errcode='23514',
        message='Purchase order currency contract must match the accounting base currency before GL posting';
    end if;

    document_amount:=round(new.quantity_delta*new.unit_cost,4);
    base_amount:=round(document_amount*source.exchange_rate,2);

    if document_amount<=0 or base_amount<=0 then
      raise exception using errcode='23514',message='Positive receipt value is required for accounting posting';
    end if;

    inventory_account:=private.accounting_resolve_mapping('inventory','global','');
    grni_account:=private.accounting_resolve_mapping('grni','global','');

    perform private.accounting_post_source_journal(
      'procurement',
      'goods_receipt_inventory_posted',
      new.id::text,
      event_date,
      'استلام مخزون — '||coalesce(source.receipt_number,new.movement_number),
      coalesce(source.receipt_number,new.movement_number),
      source.project_id,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',inventory_account,
          'debit',base_amount,
          'credit',0,
          'description',coalesce(source.description,'استلام مخزون'),
          'project_id',source.project_id,
          'cost_center_reference',source.cost_center_reference,
          'source_line_id','inventory',
          'reference',source.order_number,
          'transaction_currency',upper(source.currency),
          'foreign_amount',document_amount,
          'exchange_rate',source.exchange_rate
        ),
        jsonb_build_object(
          'account_id',grni_account,
          'debit',0,
          'credit',base_amount,
          'description','بضاعة مستلمة غير مفوترة',
          'partner_type','supplier',
          'partner_id',source.supplier_id,
          'project_id',source.project_id,
          'cost_center_reference',source.cost_center_reference,
          'source_line_id','grni',
          'reference',source.order_number,
          'transaction_currency',upper(source.currency),
          'foreign_amount',document_amount,
          'exchange_rate',source.exchange_rate
        )
      ),
      actor
    );

    return new;
  end if;

  if new.movement_type='receipt_reversal'
     and new.reversed_movement_id is not null then

    select l.journal_entry_id
    into linked_journal
    from public.accounting_source_links l
    where lower(btrim(l.source_module))='procurement'
      and lower(btrim(l.source_event))='goods_receipt_inventory_posted'
      and l.source_record_id=new.reversed_movement_id::text
      and l.source_line_id is null
      and l.source_revision=1
      and l.link_status='active'
    order by l.created_at desc
    limit 1;

    if linked_journal is null then
      return new;
    end if;

    select
      po.id as purchase_order_id
    into source
    from public.inventory_movements original
    join public.goods_receipt_items gri on gri.id=original.goods_receipt_item_id
    join public.goods_receipts gr on gr.id=gri.goods_receipt_id
    join public.purchase_orders po on po.id=gr.purchase_order_id
    where original.id=new.reversed_movement_id;

    if not found then
      raise exception using errcode='23503',message='Original procurement receipt source was not found';
    end if;

    if exists(
      select 1
      from public.supplier_invoices si
      where si.purchase_order_id=source.purchase_order_id
        and si.status in ('approved','paid')
    ) then
      raise exception using
        errcode='23514',
        message='Reverse the approved supplier invoice before reversing this accounted goods receipt';
    end if;

    perform private.accounting_reverse_source_journal(
      'procurement',
      'goods_receipt_inventory_posted',
      new.reversed_movement_id::text,
      event_date,
      coalesce(nullif(btrim(new.reason),''),'عكس استلام المخزون'),
      actor
    );

    return new;
  end if;

  return new;
end
$$;
revoke all on function private.accounting_procurement_inventory_gl_trigger()
  from public,anon,authenticated;

create or replace function private.accounting_supplier_invoice_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.approved_by);
  should_post boolean:=false;
  source_po public.purchase_orders%rowtype;
  gl_base_currency text;
  grni_account uuid;
  vat_account uuid;
  ap_account uuid;
  variance_account uuid;
  lines jsonb:='[]'::jsonb;
  line record;
  receipt_document_amount numeric(18,4);
  receipt_base_amount numeric(18,2);
  line_tax_base numeric(18,2);
  total_grni_base numeric(18,2):=0;
  total_tax_base numeric(18,2):=0;
  ap_base_amount numeric(18,2);
  variance_base_amount numeric(18,2);
  variance_foreign_amount numeric(18,4);
  line_count integer:=0;
begin
  if new.status='approved' then
    if tg_op='INSERT' then
      should_post:=true;
    elsif old.status is distinct from 'approved' then
      should_post:=true;
    end if;
  end if;

  if should_post then
    if not private.accounting_source_event_in_scope(new.invoice_date) then
      return new;
    end if;

    if new.purchase_order_id is null then
      raise exception using errcode='23514',message='Approved supplier invoice requires a purchase order for accounting posting';
    end if;

    select * into source_po
    from public.purchase_orders
    where id=new.purchase_order_id;

    if not found then
      raise exception using errcode='23503',message='Supplier invoice purchase order was not found';
    end if;

    select s.base_currency into gl_base_currency
    from public.accounting_settings s
    where s.id=true;

    if new.base_currency is null
       or upper(new.base_currency)<>upper(gl_base_currency)
       or source_po.base_currency is null
       or upper(source_po.base_currency)<>upper(gl_base_currency)
       or new.exchange_rate is null
       or new.exchange_rate<=0
       or source_po.exchange_rate is null
       or source_po.exchange_rate<=0
       or new.exchange_rate<>source_po.exchange_rate then
      raise exception using
        errcode='23514',
        message='Supplier invoice currency contract must match its purchase order and accounting base currency';
    end if;

    grni_account:=private.accounting_resolve_mapping('grni','global','');
    ap_account:=private.accounting_resolve_mapping('accounts_payable','global','');

    for line in
      select
        sil.id,
        sil.description,
        sil.tax_amount,
        sil.cost_center_reference,
        poi.quantity as po_quantity,
        poi.unit_price as po_unit_price,
        poi.discount_amount as po_discount_amount
      from public.supplier_invoice_lines sil
      join public.purchase_order_items poi on poi.id=sil.purchase_order_item_id
      where sil.supplier_invoice_id=new.id
      order by sil.id
    loop
      line_count:=line_count+1;
      receipt_document_amount:=round(
        (line.po_quantity*line.po_unit_price)-coalesce(line.po_discount_amount,0),
        4
      );
      receipt_base_amount:=round(receipt_document_amount*new.exchange_rate,2);

      if receipt_base_amount<0 then
        raise exception using errcode='23514',message='Negative GRNI release is not allowed';
      end if;

      if receipt_base_amount>0 then
        total_grni_base:=total_grni_base+receipt_base_amount;
        lines:=lines||jsonb_build_array(jsonb_build_object(
          'account_id',grni_account,
          'debit',receipt_base_amount,
          'credit',0,
          'description',coalesce(line.description,'إقفال بضاعة مستلمة غير مفوترة'),
          'partner_type','supplier',
          'partner_id',new.supplier_id,
          'project_id',new.project_id,
          'cost_center_reference',line.cost_center_reference,
          'source_line_id',line.id::text||':grni',
          'reference',new.invoice_number,
          'transaction_currency',upper(new.currency),
          'foreign_amount',receipt_document_amount,
          'exchange_rate',new.exchange_rate
        ));
      end if;

      line_tax_base:=round(coalesce(line.tax_amount,0)*new.exchange_rate,2);
      if line_tax_base<0 then
        raise exception using errcode='23514',message='Negative supplier invoice tax is not allowed';
      end if;

      if line_tax_base>0 then
        if vat_account is null then
          vat_account:=private.accounting_resolve_mapping('vat_input','global','');
        end if;
        total_tax_base:=total_tax_base+line_tax_base;
        lines:=lines||jsonb_build_array(jsonb_build_object(
          'account_id',vat_account,
          'debit',line_tax_base,
          'credit',0,
          'description','ضريبة قيمة مضافة مدخلات',
          'partner_type','supplier',
          'partner_id',new.supplier_id,
          'project_id',new.project_id,
          'cost_center_reference',line.cost_center_reference,
          'source_line_id',line.id::text||':vat',
          'reference',new.invoice_number,
          'transaction_currency',upper(new.currency),
          'foreign_amount',coalesce(line.tax_amount,0),
          'exchange_rate',new.exchange_rate
        ));
      end if;
    end loop;

    if line_count=0 then
      raise exception using errcode='23514',message='Supplier invoice lines are required for accounting posting';
    end if;

    ap_base_amount:=coalesce(
      new.base_total_amount,
      round(new.total_amount*new.exchange_rate,2)
    );

    if ap_base_amount<=0 then
      raise exception using errcode='23514',message='Positive supplier invoice payable is required';
    end if;

    variance_base_amount:=round(ap_base_amount-total_grni_base-total_tax_base,2);

    if variance_base_amount<>0 then
      variance_account:=private.accounting_resolve_mapping('purchase_price_variance','global','');
      variance_foreign_amount:=round(abs(variance_base_amount/new.exchange_rate),4);

      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',variance_account,
        'debit',case when variance_base_amount>0 then variance_base_amount else 0 end,
        'credit',case when variance_base_amount<0 then abs(variance_base_amount) else 0 end,
        'description','فرق سعر / تقريب فاتورة مورد',
        'partner_type','supplier',
        'partner_id',new.supplier_id,
        'project_id',new.project_id,
        'source_line_id','purchase_price_variance',
        'reference',new.invoice_number,
        'transaction_currency',upper(new.currency),
        'foreign_amount',variance_foreign_amount,
        'exchange_rate',new.exchange_rate
      ));
    end if;

    lines:=lines||jsonb_build_array(jsonb_build_object(
      'account_id',ap_account,
      'debit',0,
      'credit',ap_base_amount,
      'description','إثبات فاتورة مورد',
      'partner_type','supplier',
      'partner_id',new.supplier_id,
      'project_id',new.project_id,
      'source_line_id','accounts_payable',
      'reference',new.invoice_number,
      'transaction_currency',upper(new.currency),
      'foreign_amount',new.total_amount,
      'exchange_rate',new.exchange_rate
    ));

    perform private.accounting_post_source_journal(
      'procurement',
      'supplier_invoice_approved',
      new.id::text,
      new.invoice_date,
      'فاتورة مورد — '||new.invoice_number,
      new.invoice_number,
      new.project_id,
      lines,
      actor
    );

    return new;
  end if;

  if tg_op='UPDATE'
     and old.status in ('approved','paid')
     and new.status in ('cancelled','reversed')
     and old.status is distinct from new.status then

    perform private.accounting_reverse_source_journal(
      'procurement',
      'supplier_invoice_approved',
      new.id::text,
      current_date,
      coalesce(
        nullif(btrim(new.notes),''),
        'تغيير حالة فاتورة المورد إلى '||new.status
      ),
      auth.uid()
    );

    return new;
  end if;

  return new;
end
$$;
revoke all on function private.accounting_supplier_invoice_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_procurement_inventory_gl
after insert on public.inventory_movements
for each row execute function private.accounting_procurement_inventory_gl_trigger();

create trigger accounting_supplier_invoice_gl
after insert or update of status on public.supplier_invoices
for each row execute function private.accounting_supplier_invoice_gl_trigger();
