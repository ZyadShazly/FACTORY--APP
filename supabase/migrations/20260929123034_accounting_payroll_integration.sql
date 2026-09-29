-- NextEP accounting integration: payroll approval/accrual and payroll payment.
-- Draft/recalculation remains non-financial. Existing historical payroll rows are not backfilled.
-- Approved/paid payroll is operationally immutable today; no artificial reversal API is introduced.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values
(
  'employee_advances_receivable',
  'سلف وعهد الموظفين',
  'Employee Advances / Receivable',
  'payroll',
  array['asset']::text[],
  '1.1.05',
  'حساب أصل الموظفين الذي ينخفض عند استرداد سلفة أو عهدة من الراتب المعتمد.',
  true,
  131
),
(
  'payroll_deductions_clearing',
  'مقابل خصومات الرواتب',
  'Payroll Deductions Clearing',
  'payroll',
  array['liability','asset','expense','revenue']::text[],
  null,
  'الحساب الدائن مقابل الخصومات العامة في الراتب. يحدد الـOwner طبيعته حسب سياسة الخصم لأن المصدر الحالي لا يصنف الخصم كالتزام أو استرداد أصل أو تخفيض مصروف.',
  true,
  132
)
on conflict(mapping_key) do nothing;

create or replace function private.accounting_payroll_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.approved_by);
  accrual_date date:=greatest(
    new.payroll_month,
    least(
      (new.payroll_month+interval '1 month - 1 day')::date,
      coalesce(new.approved_at::date,current_date)
    )
  );
  payment_date date:=coalesce(new.paid_at::date,current_date);
  payroll_expense_account uuid;
  payroll_payable_account uuid;
  employee_advance_account uuid;
  deduction_account uuid;
  bank_account uuid;
  net_base numeric(18,2);
  deduction_base numeric(18,2);
  advance_base numeric(18,2);
  gross_base numeric(18,2);
  reference_value text;
  accrual_lines jsonb:='[]'::jsonb;
begin
  if old.status in ('draft','rejected')
     and new.status='approved'
     and old.status is distinct from new.status then

    if not private.accounting_source_event_in_scope(accrual_date) then
      return new;
    end if;

    net_base:=round(coalesce(new.net_salary,0),2);
    deduction_base:=round(coalesce(new.deductions,0),2);
    advance_base:=round(coalesce(new.advances,0),2);
    gross_base:=round(net_base+deduction_base+advance_base,2);

    if least(net_base,deduction_base,advance_base,gross_base)<0 then
      raise exception using errcode='23514',
        message='Negative payroll accounting values are not allowed';
    end if;
    if gross_base<=0 then
      raise exception using errcode='23514',
        message='Positive approved payroll amount is required for accounting posting';
    end if;

    payroll_expense_account:=private.accounting_resolve_mapping(
      'payroll_expense','global',''
    );
    reference_value:='payroll:'||new.id::text;

    accrual_lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',payroll_expense_account,
        'debit',gross_base,
        'credit',0,
        'description','تكلفة راتب معتمد',
        'partner_type','employee',
        'partner_id',new.employee_id,
        'project_id',new.project_id,
        'source_line_id','payroll_expense',
        'reference',reference_value
      )
    );

    if net_base>0 then
      payroll_payable_account:=private.accounting_resolve_mapping(
        'payroll_payable','global',''
      );
      accrual_lines:=accrual_lines||jsonb_build_array(jsonb_build_object(
        'account_id',payroll_payable_account,
        'debit',0,
        'credit',net_base,
        'description','صافي راتب مستحق',
        'partner_type','employee',
        'partner_id',new.employee_id,
        'project_id',new.project_id,
        'source_line_id','payroll_payable',
        'reference',reference_value
      ));
    end if;

    if advance_base>0 then
      employee_advance_account:=private.accounting_resolve_mapping(
        'employee_advances_receivable','global',''
      );
      accrual_lines:=accrual_lines||jsonb_build_array(jsonb_build_object(
        'account_id',employee_advance_account,
        'debit',0,
        'credit',advance_base,
        'description',coalesce(nullif(btrim(new.advance_reason),''),'استرداد سلفة موظف'),
        'partner_type','employee',
        'partner_id',new.employee_id,
        'project_id',new.project_id,
        'source_line_id','employee_advance_recovery',
        'reference',reference_value
      ));
    end if;

    if deduction_base>0 then
      deduction_account:=private.accounting_resolve_mapping(
        'payroll_deductions_clearing','global',''
      );
      accrual_lines:=accrual_lines||jsonb_build_array(jsonb_build_object(
        'account_id',deduction_account,
        'debit',0,
        'credit',deduction_base,
        'description',coalesce(nullif(btrim(new.deduction_reason),''),'خصومات راتب'),
        'partner_type','employee',
        'partner_id',new.employee_id,
        'project_id',new.project_id,
        'source_line_id','payroll_deduction',
        'reference',reference_value
      ));
    end if;

    perform private.accounting_post_source_journal(
      'payroll',
      'payroll_accrual_posted',
      new.id::text,
      accrual_date,
      'استحقاق راتب — '||to_char(new.payroll_month,'YYYY-MM'),
      reference_value,
      new.project_id,
      accrual_lines,
      actor
    );

    return new;
  end if;

  if old.status='approved'
     and new.status='paid'
     and old.status is distinct from new.status then

    -- Do not create an orphan payment for payroll that was approved before
    -- accounting activation/enablement and therefore has no GL accrual.
    if not exists(
      select 1
      from public.accounting_source_links l
      where lower(btrim(l.source_module))='payroll'
        and lower(btrim(l.source_event))='payroll_accrual_posted'
        and l.source_record_id=new.id::text
        and l.source_line_id is null
        and l.source_revision=1
        and l.link_status='active'
    ) then
      return new;
    end if;

    net_base:=round(coalesce(new.net_salary,0),2);

    if net_base<0 then
      raise exception using errcode='23514',
        message='Negative payroll payment amount is not allowed';
    end if;

    if net_base=0 then
      return new;
    end if;

    if not private.accounting_source_event_in_scope(payment_date) then
      return new;
    end if;

    payroll_payable_account:=private.accounting_resolve_mapping(
      'payroll_payable','global',''
    );
    bank_account:=private.accounting_resolve_mapping(
      'default_cash_bank','global',''
    );
    reference_value:='payroll_payment:'||new.id::text;

    perform private.accounting_post_source_journal(
      'payroll',
      'payroll_payment_posted',
      new.id::text,
      payment_date,
      'صرف راتب — '||to_char(new.payroll_month,'YYYY-MM'),
      reference_value,
      new.project_id,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',payroll_payable_account,
          'debit',net_base,
          'credit',0,
          'description','تسوية راتب مستحق',
          'partner_type','employee',
          'partner_id',new.employee_id,
          'project_id',new.project_id,
          'source_line_id','payroll_payable',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',bank_account,
          'debit',0,
          'credit',net_base,
          'description','صرف راتب',
          'partner_type','employee',
          'partner_id',new.employee_id,
          'project_id',new.project_id,
          'source_line_id','cash_bank',
          'reference',reference_value
        )
      ),
      coalesce(auth.uid(),new.approved_by)
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_payroll_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_payroll_gl
after update of status on public.payroll
for each row execute function private.accounting_payroll_gl_trigger();
