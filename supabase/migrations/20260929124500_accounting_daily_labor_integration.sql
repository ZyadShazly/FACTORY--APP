-- NextEP accounting integration: Daily Labor approval/accrual and payment.
-- Draft/rejected correction remains non-financial. Existing historical shifts are not backfilled.
-- Approved/paid shifts are operationally immutable today; no artificial reversal API is introduced.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values
(
  'daily_labor_deductions_clearing',
  'مقابل خصومات العمالة اليومية',
  'Daily Labor Deductions Clearing',
  'daily_labor',
  array['liability','asset','expense','revenue']::text[],
  null,
  'الحساب الدائن مقابل خصومات العمالة اليومية. يحدده الـOwner حسب طبيعة الخصم لأن المصدر لا يصنف الخصم كالتزام أو استرداد أصل أو تخفيض مصروف.',
  true,
  161
)
on conflict(mapping_key) do nothing;

create or replace function private.accounting_daily_labor_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.reviewed_by,new.paid_by,new.created_by);
  accrual_date date:=coalesce(new.work_date,current_date);
  payment_date date:=coalesce(new.paid_at::date,current_date);
  labor_expense_account uuid;
  labor_payable_account uuid;
  deduction_account uuid;
  bank_account uuid;
  net_base numeric(18,2);
  deduction_base numeric(18,2);
  gross_base numeric(18,2);
  reference_value text;
  accrual_lines jsonb:='[]'::jsonb;
begin
  if old.review_status='draft'
     and new.review_status='approved'
     and old.review_status is distinct from new.review_status then

    if not private.accounting_source_event_in_scope(accrual_date) then
      return new;
    end if;

    net_base:=round(coalesce(new.net_amount,0),2);
    deduction_base:=round(coalesce(new.deduction_amount,0),2);
    gross_base:=round(net_base+deduction_base,2);

    if least(net_base,deduction_base,gross_base)<0 then
      raise exception using errcode='23514',
        message='Negative daily labor accounting values are not allowed';
    end if;
    if gross_base<=0 then
      raise exception using errcode='23514',
        message='Positive approved daily labor amount is required for accounting posting';
    end if;

    labor_expense_account:=private.accounting_resolve_mapping(
      'daily_labor_expense','global',''
    );
    reference_value:='daily_labor:'||new.id::text;

    accrual_lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',labor_expense_account,
        'debit',gross_base,
        'credit',0,
        'description','تكلفة عمالة يومية — '||new.worker_name,
        'project_id',new.project_id,
        'source_line_id','daily_labor_expense',
        'reference',reference_value
      )
    );

    if net_base>0 then
      labor_payable_account:=private.accounting_resolve_mapping(
        'daily_labor_payable','global',''
      );
      accrual_lines:=accrual_lines||jsonb_build_array(jsonb_build_object(
        'account_id',labor_payable_account,
        'debit',0,
        'credit',net_base,
        'description','عمالة يومية مستحقة — '||new.worker_name,
        'project_id',new.project_id,
        'source_line_id','daily_labor_payable',
        'reference',reference_value
      ));
    end if;

    if deduction_base>0 then
      deduction_account:=private.accounting_resolve_mapping(
        'daily_labor_deductions_clearing','global',''
      );
      accrual_lines:=accrual_lines||jsonb_build_array(jsonb_build_object(
        'account_id',deduction_account,
        'debit',0,
        'credit',deduction_base,
        'description',coalesce(nullif(btrim(new.deduction_reason),''),'خصومات عمالة يومية'),
        'project_id',new.project_id,
        'source_line_id','daily_labor_deduction',
        'reference',reference_value
      ));
    end if;

    perform private.accounting_post_source_journal(
      'daily_labor',
      'daily_labor_accrual_posted',
      new.id::text,
      accrual_date,
      'استحقاق عمالة يومية — '||new.worker_name,
      reference_value,
      new.project_id,
      accrual_lines,
      actor
    );

    return new;
  end if;

  if old.payment_status<>'paid'
     and new.payment_status='paid'
     and old.payment_status is distinct from new.payment_status then

    -- No orphan payment GL for shifts approved before accounting activation.
    if not exists(
      select 1
      from public.accounting_source_links l
      where lower(btrim(l.source_module))='daily_labor'
        and lower(btrim(l.source_event))='daily_labor_accrual_posted'
        and l.source_record_id=new.id::text
        and l.source_line_id is null
        and l.source_revision=1
        and l.link_status='active'
    ) then
      return new;
    end if;

    net_base:=round(coalesce(new.net_amount,0),2);

    if net_base<0 then
      raise exception using errcode='23514',
        message='Negative daily labor payment amount is not allowed';
    end if;
    if net_base=0 then
      return new;
    end if;

    if not private.accounting_source_event_in_scope(payment_date) then
      return new;
    end if;

    labor_payable_account:=private.accounting_resolve_mapping(
      'daily_labor_payable','global',''
    );
    bank_account:=private.accounting_resolve_mapping(
      'default_cash_bank','global',''
    );
    reference_value:=coalesce(
      nullif(btrim(new.payment_reference),''),
      'daily_labor_payment:'||new.id::text
    );

    perform private.accounting_post_source_journal(
      'daily_labor',
      'daily_labor_payment_posted',
      new.id::text,
      payment_date,
      'صرف عمالة يومية — '||new.worker_name,
      reference_value,
      new.project_id,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',labor_payable_account,
          'debit',net_base,
          'credit',0,
          'description','تسوية عمالة يومية مستحقة — '||new.worker_name,
          'project_id',new.project_id,
          'source_line_id','daily_labor_payable',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',bank_account,
          'debit',0,
          'credit',net_base,
          'description','صرف عمالة يومية — '||new.worker_name,
          'project_id',new.project_id,
          'source_line_id','cash_bank',
          'reference',reference_value
        )
      ),
      coalesce(auth.uid(),new.paid_by)
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_daily_labor_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_daily_labor_gl
after update of review_status,payment_status on public.daily_labor
for each row execute function private.accounting_daily_labor_gl_trigger();
