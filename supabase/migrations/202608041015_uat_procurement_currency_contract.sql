-- UAT-006: persist an auditable procurement currency/conversion contract.
-- Additive only. Existing documents are not rewritten or guessed.

begin;

alter table public.supplier_quotes
  add column if not exists base_currency text,
  add column if not exists exchange_rate numeric,
  add column if not exists rate_date date,
  add column if not exists base_total_amount numeric;

alter table public.purchase_orders
  add column if not exists base_currency text,
  add column if not exists exchange_rate numeric,
  add column if not exists rate_date date,
  add column if not exists base_total_amount numeric;

alter table public.supplier_invoices
  add column if not exists base_currency text,
  add column if not exists exchange_rate numeric,
  add column if not exists rate_date date,
  add column if not exists base_total_amount numeric;

alter table public.supplier_quotes
  drop constraint if exists supplier_quotes_currency_conversion_check;
alter table public.supplier_quotes
  add constraint supplier_quotes_currency_conversion_check check (
    base_currency is null
    or (
      base_currency ~ '^[A-Z]{3}$'
      and exchange_rate is not null and exchange_rate > 0
      and rate_date is not null
      and base_total_amount is not null and base_total_amount >= 0
      and ((currency = base_currency and exchange_rate = 1) or currency <> base_currency)
    )
  ) not valid;

alter table public.purchase_orders
  drop constraint if exists purchase_orders_currency_conversion_check;
alter table public.purchase_orders
  add constraint purchase_orders_currency_conversion_check check (
    base_currency is null
    or (
      base_currency ~ '^[A-Z]{3}$'
      and exchange_rate is not null and exchange_rate > 0
      and rate_date is not null
      and base_total_amount is not null and base_total_amount >= 0
      and ((currency = base_currency and exchange_rate = 1) or currency <> base_currency)
    )
  ) not valid;

alter table public.supplier_invoices
  drop constraint if exists supplier_invoices_currency_conversion_check;
alter table public.supplier_invoices
  add constraint supplier_invoices_currency_conversion_check check (
    base_currency is null
    or (
      base_currency ~ '^[A-Z]{3}$'
      and exchange_rate is not null and exchange_rate > 0
      and rate_date is not null
      and base_total_amount is not null and base_total_amount >= 0
      and ((currency = base_currency and exchange_rate = 1) or currency <> base_currency)
    )
  ) not valid;

create or replace view public.procurement_currency_reconciliation as
select 'supplier_quote'::text as document_type, id, quote_number as document_number,
       currency, base_currency, exchange_rate, rate_date, null::numeric as document_total,
       base_total_amount,
       case
         when base_currency is null then 'missing_conversion_contract'
         when currency = base_currency and exchange_rate <> 1 then 'same_currency_rate_not_one'
         when currency <> base_currency and (exchange_rate is null or exchange_rate <= 0 or rate_date is null) then 'missing_foreign_rate'
         else 'ok'
       end as reconciliation_status
from public.supplier_quotes
union all
select 'purchase_order', id, order_number, currency, base_currency, exchange_rate, rate_date,
       total_amount, base_total_amount,
       case
         when base_currency is null then 'missing_conversion_contract'
         when currency = base_currency and exchange_rate <> 1 then 'same_currency_rate_not_one'
         when currency <> base_currency and (exchange_rate is null or exchange_rate <= 0 or rate_date is null) then 'missing_foreign_rate'
         else 'ok'
       end
from public.purchase_orders
union all
select 'supplier_invoice', id, invoice_number, currency, base_currency, exchange_rate, rate_date,
       total_amount, base_total_amount,
       case
         when base_currency is null then 'missing_conversion_contract'
         when currency = base_currency and exchange_rate <> 1 then 'same_currency_rate_not_one'
         when currency <> base_currency and (exchange_rate is null or exchange_rate <= 0 or rate_date is null) then 'missing_foreign_rate'
         else 'ok'
       end
from public.supplier_invoices;

comment on view public.procurement_currency_reconciliation is
  'Read-only UAT reconciliation for procurement documents with missing or inconsistent currency conversion metadata.';

revoke all on public.procurement_currency_reconciliation from public, anon;
grant select on public.procurement_currency_reconciliation to authenticated;

commit;
