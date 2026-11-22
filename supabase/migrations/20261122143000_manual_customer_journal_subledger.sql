-- Manual customer journal lines join the operational customer subledger.
-- Additive only: historical journals without partner_id are left untouched.

create or replace function private.accounting_validate_manual_customer_partner()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  origin_value text;
  receivable_account uuid;
begin
  if new.partner_type is distinct from 'customer' or new.partner_id is null then
    return new;
  end if;

  select j.entry_origin into origin_value
  from public.accounting_journal_entries j
  where j.id=new.journal_entry_id;

  if origin_value not in ('manual','opening') then
    return new;
  end if;

  receivable_account:=private.accounting_resolve_mapping('accounts_receivable','global','');
  if receivable_account is null or new.account_id is distinct from receivable_account then
    raise exception using errcode='23514',
      message='ربط العميل متاح فقط على حساب العملاء المدينين (Accounts Receivable)';
  end if;

  if not exists (
    select 1 from public.customers c
    where c.id=new.partner_id and c.archived_at is null
  ) then
    raise exception using errcode='23503',message='Active customer required for customer journal line';
  end if;

  return new;
end
$$;
revoke all on function private.accounting_validate_manual_customer_partner() from public,anon,authenticated;

drop trigger if exists accounting_validate_manual_customer_partner on public.accounting_journal_lines;
create trigger accounting_validate_manual_customer_partner
before insert or update of account_id,partner_type,partner_id on public.accounting_journal_lines
for each row execute function private.accounting_validate_manual_customer_partner();

create or replace function private.customer_due(target_customer uuid)
returns numeric
language sql
stable
set search_path=''
as $$
  select greatest(0,
    coalesce((
      select sum(s.total)
      from public.sales s
      where s.customer_id=target_customer
        and coalesce(s.status,'posted')<>'cancelled'
    ),0)
    + coalesce((
      select sum(r.rental_fee)
      from public.rentals r
      where r.customer_id=target_customer
        and coalesce(r.status,'active')<>'cancelled'
    ),0)
    + coalesce((
      select sum(p.revenue)
      from public.projects p
      where p.customer_id=target_customer
        and p.lifecycle='closed'
        and coalesce(p.revenue,0)>0
    ),0)
    - coalesce((
      select sum(
        case when cr.transaction_classification is null
          then cr.amount
          else cr.settlement_amount + cr.allocated_advance_amount
        end
      )
      from public.customer_receipts cr
      where cr.customer_id=target_customer
        and cr.status='posted'
    ),0)
    - coalesce((
      select sum(ca.amount)
      from public.customer_adjustments ca
      where ca.customer_id=target_customer
        and ca.status='posted'
    ),0)
    + coalesce((
      select sum(l.debit-l.credit)
      from public.accounting_journal_lines l
      join public.accounting_journal_entries j on j.id=l.journal_entry_id
      where l.partner_type='customer'
        and l.partner_id=target_customer
        and l.account_id=private.accounting_resolve_mapping('accounts_receivable','global','')
        and j.status='posted'
        and j.entry_origin in ('manual','opening')
        and j.source_module is null
    ),0)
  )
$$;

create or replace function public.get_customer_manual_journal_lines()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;
begin
  if not private.accounting_permission_allowed('accounting_view') then
    raise exception using errcode='42501',message='Accounting view permission required';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id',l.partner_id,
      'journal_entry_id',j.id,
      'entry_number',j.entry_number,
      'entry_date',j.entry_date,
      'journal_description',j.description,
      'line_description',l.description,
      'debit',l.debit,
      'credit',l.credit,
      'reference',coalesce(l.reference,j.reference)
    ) order by j.entry_date,j.entry_number,l.line_number
  ),'[]'::jsonb)
  into result
  from public.accounting_journal_lines l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  where l.partner_type='customer'
    and l.partner_id is not null
    and j.status='posted'
    and j.entry_origin in ('manual','opening')
    and j.source_module is null;

  return result;
end
$$;
revoke all on function public.get_customer_manual_journal_lines() from public,anon;
grant execute on function public.get_customer_manual_journal_lines() to authenticated;
