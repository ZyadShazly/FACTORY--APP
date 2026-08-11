-- Add period commercial/cash reporting without duplicating operational ledgers.
begin;

create or replace function public.get_operational_reporting_summary(
  date_from date default (date_trunc('month',current_date)::date-interval '11 months')::date,
  date_to date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  from_date date:=coalesce(date_from,(date_trunc('month',current_date)::date-interval '11 months')::date);
  to_date date:=coalesce(date_to,current_date);
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager','accountant') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Financial reporting access required';
  end if;
  if from_date>to_date then
    raise exception using errcode='22007',message='Invalid reporting date range';
  end if;

  return jsonb_build_object(
    'period_sales',coalesce((select sum(sale.total) from public.sales sale where sale.status='posted' and sale.sale_date between from_date and to_date),0),
    'period_rentals',coalesce((select sum(rental.rental_fee) from public.rentals rental where rental.status<>'cancelled' and rental.start_date between from_date and to_date),0),
    'period_expenses',coalesce((select sum(expense.amount) from public.expenses expense where expense.cancelled_at is null and expense.expense_date between from_date and to_date),0),
    'period_customer_receipts',coalesce((select sum(receipt.amount) from public.customer_receipts receipt where receipt.status='posted' and receipt.receipt_date between from_date and to_date),0),
    'period_supplier_payments',coalesce((select sum(payment.amount) from public.supplier_payments payment where payment.status='posted' and payment.payment_date between from_date and to_date),0),
    'payroll_net_final',coalesce((select sum(payroll.net_salary) from public.payroll payroll where payroll.status in ('approved','paid') and payroll.payroll_month between date_trunc('month',from_date)::date and date_trunc('month',to_date)::date),0),
    'customer_outstanding',coalesce((select sum(private.customer_due(customer.id)) from public.customers customer where customer.archived_at is null),0),
    'supplier_outstanding',coalesce((select sum(private.supplier_due(supplier.id)) from public.suppliers supplier where supplier.archived_at is null),0),
    'customer_unallocated_advances',coalesce((select sum(greatest(receipt.advance_amount-receipt.allocated_advance_amount,0)) from public.customer_receipts receipt where receipt.status='posted'),0),
    'supplier_unallocated_advances',coalesce((select sum(greatest(payment.advance_amount-payment.allocated_advance_amount,0)) from public.supplier_payments payment where payment.status='posted'),0)
  );
end
$$;

revoke all on function public.get_operational_reporting_summary(date,date) from public,anon;
grant execute on function public.get_operational_reporting_summary(date,date) to authenticated;

comment on function public.get_operational_reporting_summary(date,date) is
  'Protected commercial, cash, expense, payroll and outstanding-balance summary derived from canonical posted records.';

commit;
