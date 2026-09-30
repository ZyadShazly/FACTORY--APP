-- NextEP accounting integration: non-cash customer adjustments.
-- Each current adjustment type reduces customer receivable.
-- Existing historical adjustments are not backfilled.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values
(
  'customer_adjustment_commercial_discount',
  'خصومات تجارية للعملاء',
  'Customer Commercial Discounts',
  'customers',
  array['revenue']::text[],
  '4.4',
  'حساب مقابل للإيراد يُحمّل بالخصومات التجارية التي تخفض ذمة العميل.',
  true,
  35
),
(
  'customer_adjustment_withholding_tax',
  'ضريبة استقطاع مستحقة التحصيل',
  'Withholding Tax Receivable',
  'customers',
  array['asset']::text[],
  '1.1.09',
  'أصل متداول يمثل ضريبة الاستقطاع المحتجزة من العميل.',
  true,
  36
),
(
  'customer_adjustment_retention',
  'مبالغ محتجزة لدى العملاء',
  'Customer Retention Receivable',
  'customers',
  array['asset']::text[],
  '1.1.10',
  'أصل متداول يمثل مبالغ Retention المحتجزة لدى العميل.',
  true,
  37
),
(
  'customer_adjustment_bank_charge',
  'مصاريف بنكية على تسويات العملاء',
  'Customer Adjustment Bank Charges',
  'customers',
  array['expense']::text[],
  '6.8',
  'مصروف بنكي يخفض ذمة العميل في التسويات غير النقدية.',
  true,
  38
),
(
  'customer_adjustment_other',
  'تسويات عملاء أخرى',
  'Other Customer Adjustments',
  'customers',
  array['asset','liability','equity','revenue','cost_of_sales','expense']::text[],
  '6.9',
  'حساب قابل للتهيئة للتسويات غير النقدية الأخرى التي تخفض ذمة العميل.',
  true,
  39
)
on conflict(mapping_key) do update set
  label_ar=excluded.label_ar,
  label_en=excluded.label_en,
  module=excluded.module,
  expected_account_types=excluded.expected_account_types,
  suggested_account_code=excluded.suggested_account_code,
  description=excluded.description,
  required_for_auto_posting=excluded.required_for_auto_posting,
  sort_order=excluded.sort_order,
  is_active=true;

create or replace function private.accounting_customer_adjustment_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.created_by,new.reversed_by);
  event_date date:=coalesce(new.adjustment_date,current_date);
  ar_account uuid;
  adjustment_account uuid;
  mapping_key text;
  amount_base numeric(18,2);
  reference_value text;
begin
  if tg_op='INSERT' and new.status='posted' then
    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    amount_base:=round(coalesce(new.amount,0),2);
    if amount_base<=0 then
      raise exception using errcode='23514',
        message='Positive customer adjustment amount is required for accounting posting';
    end if;

    mapping_key:=case new.adjustment_type
      when 'commercial_discount' then 'customer_adjustment_commercial_discount'
      when 'withholding_tax' then 'customer_adjustment_withholding_tax'
      when 'retention' then 'customer_adjustment_retention'
      when 'bank_charge' then 'customer_adjustment_bank_charge'
      when 'other' then 'customer_adjustment_other'
      else null
    end;

    if mapping_key is null then
      raise exception using errcode='23514',
        message='Unsupported customer adjustment type for accounting posting';
    end if;

    ar_account:=private.accounting_resolve_mapping(
      'accounts_receivable','global',''
    );
    adjustment_account:=private.accounting_resolve_mapping(
      mapping_key,'global',''
    );
    reference_value:='customer_adjustment:'||new.id::text;

    perform private.accounting_post_source_journal(
      'customers',
      'customer_adjustment_posted',
      new.id::text,
      event_date,
      'تسوية غير نقدية للعميل — '||new.adjustment_type,
      reference_value,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',adjustment_account,
          'debit',amount_base,
          'credit',0,
          'description',coalesce(nullif(btrim(new.reason),''),new.adjustment_type),
          'partner_type','customer',
          'partner_id',new.customer_id,
          'source_line_id',mapping_key,
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',ar_account,
          'debit',0,
          'credit',amount_base,
          'description','تخفيض ذمة العميل',
          'partner_type','customer',
          'partner_id',new.customer_id,
          'source_line_id','accounts_receivable',
          'reference',reference_value
        )
      ),
      actor
    );

    return new;
  end if;

  if tg_op='UPDATE'
     and old.status='posted'
     and new.status='reversed'
     and old.status is distinct from new.status then

    perform private.accounting_reverse_source_journal(
      'customers',
      'customer_adjustment_posted',
      new.id::text,
      coalesce(new.reversed_at::date,current_date),
      coalesce(nullif(btrim(new.reversal_reason),''),'عكس تسوية العميل'),
      actor
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_customer_adjustment_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_customer_adjustments_gl
after insert or update of status on public.customer_adjustments
for each row execute function private.accounting_customer_adjustment_gl_trigger();
