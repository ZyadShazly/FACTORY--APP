alter table public.sales
  drop constraint if exists sales_total_consistency_check;

alter table public.sales
  add constraint sales_total_consistency_check
  check (
    status='cancelled'
    or round(total,2)=round((qty*unit_price)+coalesce(tax_amount,0),2)
  )
  not valid;
