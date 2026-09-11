-- Pilot blocker: closing a project with contracted revenue did not create any
-- receivable effect for its customer. Treat closed project revenue as a customer
-- charge in the canonical balance calculation. The project itself is the source
-- document, so no duplicate cash/AR row is introduced.

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
  )
$$;
