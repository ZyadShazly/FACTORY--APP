-- Align supplier balances with both legacy direct purchases and approved procurement invoices.
-- Existing cash classifications remain unchanged and visible as historical evidence.
begin;

create index if not exists supplier_invoices_supplier_status_idx
on public.supplier_invoices(supplier_id,status);

create or replace function private.supplier_due(target_supplier uuid)
returns numeric
language sql
stable
security invoker
set search_path=''
as $$
  select greatest(0,
    coalesce((select sum(mp.qty*mp.unit_cost) from public.material_purchases mp where mp.supplier_id=target_supplier),0)
    + coalesce((select sum(si.total_amount) from public.supplier_invoices si where si.supplier_id=target_supplier and si.status in ('approved','paid')),0)
    - coalesce((select sum(case when sp.transaction_classification is null then sp.amount else sp.settlement_amount+sp.allocated_advance_amount end)
      from public.supplier_payments sp where sp.supplier_id=target_supplier and sp.status='posted'),0)
  )
$$;

create or replace function public.get_supplier_invoices_visible()
returns setof public.supplier_invoices
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager','accountant') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Supplier financial access required';
  end if;
  return query
    select invoice.* from public.supplier_invoices invoice
    where invoice.status in ('approved','paid','cancelled','reversed')
    order by invoice.invoice_date,invoice.created_at;
end
$$;

revoke all on function private.supplier_due(uuid) from public,anon,authenticated;
revoke all on function public.get_supplier_invoices_visible() from public,anon,authenticated;
grant execute on function public.get_supplier_invoices_visible() to authenticated;

commit;
