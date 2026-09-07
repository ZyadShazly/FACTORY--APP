-- Make supplier invoice approval idempotent so UI retries/double-clicks do not
-- surface a false failure after a successful approval.
--
-- The existing implementation is preserved under a private-by-convention
-- implementation name. The public wrapper serializes approvals per purchase
-- order and returns the already-created invoice when the same invoice number
-- is retried for the same PO.

alter function public.approve_supplier_invoice(jsonb)
  rename to approve_supplier_invoice_impl_20260907;

revoke all on function public.approve_supplier_invoice_impl_20260907(jsonb) from public, anon, authenticated;

create or replace function public.approve_supplier_invoice(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare
  po_id uuid;
  invoice_no text;
  existing public.supplier_invoices%rowtype;
begin
  po_id := nullif(payload->>'purchase_order_id','')::uuid;
  invoice_no := btrim(coalesce(payload->>'invoice_number',''));

  if po_id is null then
    raise exception using errcode='22023', message='Purchase order is required';
  end if;
  if invoice_no='' then
    raise exception using errcode='22023', message='Invoice number is required';
  end if;

  -- Serialize repeated approvals for the same purchase order. This protects
  -- against double-clicks, browser retries, and overlapping client requests.
  perform 1 from public.purchase_orders where id=po_id for update;
  if not found then
    raise exception using errcode='P0002', message='Purchase order was not found';
  end if;

  select * into existing
  from public.supplier_invoices
  where purchase_order_id=po_id
    and btrim(coalesce(invoice_number,''))=invoice_no
  order by created_at desc
  limit 1;

  if found then
    return to_jsonb(existing) || jsonb_build_object('idempotent_replay',true);
  end if;

  return public.approve_supplier_invoice_impl_20260907(payload);
end
$$;

revoke all on function public.approve_supplier_invoice(jsonb) from public, anon;
grant execute on function public.approve_supplier_invoice(jsonb) to authenticated;

comment on function public.approve_supplier_invoice(jsonb) is
'Idempotent supplier-invoice approval wrapper. Repeated approval of the same invoice number for the same purchase order returns the existing invoice instead of failing.';
