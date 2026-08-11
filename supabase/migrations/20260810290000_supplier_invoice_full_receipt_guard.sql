-- Keep the current one-invoice-per-order workflow consistent with physical receipts.
-- No historical invoice or receipt is rewritten.
begin;

create or replace function private.enforce_supplier_invoice_full_receipt()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  order_row public.purchase_orders%rowtype;
begin
  if new.status<>'approved' or old.status='approved' then return new; end if;
  if new.purchase_order_id is null then
    raise exception using errcode='23514',message='Approved supplier invoice requires a purchase order';
  end if;

  select * into order_row from public.purchase_orders where id=new.purchase_order_id for update;
  if not found or order_row.status<>'fully_received' then
    raise exception using errcode='23514',message='Purchase order must be fully received before invoice approval';
  end if;

  if exists(
    select 1 from public.supplier_invoices existing
    where existing.id<>new.id and existing.purchase_order_id=new.purchase_order_id
      and existing.status in ('approved','paid')
  ) then
    raise exception using errcode='23505',message='Purchase order already has an approved supplier invoice';
  end if;

  if exists(
    select 1 from public.supplier_invoices existing
    where existing.id<>new.id and existing.supplier_id=new.supplier_id
      and lower(btrim(existing.invoice_number))=lower(btrim(new.invoice_number))
      and existing.status not in ('cancelled','reversed','rejected')
  ) then
    raise exception using errcode='23505',message='Supplier invoice number already exists';
  end if;

  if exists(
    select 1
    from public.purchase_order_items poi
    left join lateral(
      select count(*) line_count,coalesce(sum(sil.quantity),0) invoiced_quantity
      from public.supplier_invoice_lines sil
      where sil.supplier_invoice_id=new.id and sil.purchase_order_item_id=poi.id
    ) invoice_line on true
    where poi.purchase_order_id=new.purchase_order_id
      and (invoice_line.line_count<>1 or invoice_line.invoiced_quantity<>poi.received_quantity or poi.received_quantity<>poi.quantity)
  ) then
    raise exception using errcode='23514',message='Invoice lines must match every fully received purchase order line';
  end if;

  return new;
end
$$;

drop trigger if exists supplier_invoice_full_receipt_guard on public.supplier_invoices;
create trigger supplier_invoice_full_receipt_guard
before update of status on public.supplier_invoices
for each row execute function private.enforce_supplier_invoice_full_receipt();

revoke all on function private.enforce_supplier_invoice_full_receipt() from public,anon,authenticated;

commit;
