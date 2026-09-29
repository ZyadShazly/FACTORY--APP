-- NextEP accounting integration: operational expenses.
-- The current expense source stores one gross spent amount only.
-- It does not expose a VAT split, payable state, supplier, or payment account.
-- Existing historical expenses are not backfilled.

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
  bank_account uuid;
  amount_base numeric(18,2);
  reference_value text;
begin
  if tg_op='INSERT' then
    if new.cancelled_at is not null then
      return new;
    end if;

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    amount_base:=round(coalesce(new.amount,0),2);
    if amount_base<=0 then
      raise exception using errcode='23514',
        message='Positive expense amount is required for accounting posting';
    end if;

    expense_account:=private.accounting_resolve_mapping(
      'expense_default','global',''
    );
    bank_account:=private.accounting_resolve_mapping(
      'default_cash_bank','global',''
    );
    reference_value:='expense:'||new.id::text;

    perform private.accounting_post_source_journal(
      'expenses',
      'expense_posted',
      new.id::text,
      event_date,
      'مصروف — '||new.category,
      reference_value,
      new.project_id,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',expense_account,
          'debit',amount_base,
          'credit',0,
          'description',new.category,
          'project_id',new.project_id,
          'source_line_id','expense',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',bank_account,
          'debit',0,
          'credit',amount_base,
          'description','سداد مصروف',
          'project_id',new.project_id,
          'source_line_id','cash_bank',
          'reference',reference_value
        )
      ),
      actor
    );

    return new;
  end if;

  if tg_op='UPDATE'
     and old.cancelled_at is null
     and new.cancelled_at is not null then

    perform private.accounting_reverse_source_journal(
      'expenses',
      'expense_posted',
      new.id::text,
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

create trigger accounting_expenses_gl
after insert or update of cancelled_at on public.expenses
for each row execute function private.accounting_expense_gl_trigger();
