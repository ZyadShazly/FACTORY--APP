-- Rollback-safe regression coverage for procurement foundation.
begin;

DO $$
DECLARE
  v_user uuid;
  v_project uuid;
  v_supplier uuid;
  v_pr uuid;
  v_pr_item uuid;
  v_po uuid;
  v_po_item uuid;
  v_receipt uuid;
  v_receipt_item uuid;
  v_invoice uuid;
BEGIN
  select id into v_user from public.profiles limit 1;
  select id into v_project from public.projects limit 1;
  select id into v_supplier from public.suppliers limit 1;

  if v_user is null or v_supplier is null then
    raise exception 'Procurement smoke test requires at least one profile and supplier';
  end if;

  insert into public.purchase_requests(requested_by, project_id, justification)
  values (v_user, v_project, 'rollback-safe procurement smoke test')
  returning id into v_pr;

  insert into public.purchase_request_items(purchase_request_id, description, quantity, estimated_unit_cost, sequence)
  values (v_pr, 'Smoke material', 2, 100, 1)
  returning id into v_pr_item;

  insert into public.purchase_orders(purchase_request_id, supplier_id, project_id, created_by, subtotal, tax_amount, total_amount)
  values (v_pr, v_supplier, v_project, v_user, 200, 30, 230)
  returning id into v_po;

  insert into public.purchase_order_items(purchase_order_id, purchase_request_item_id, description, quantity, unit_price, tax_amount, sequence)
  values (v_po, v_pr_item, 'Smoke material', 2, 100, 30, 1)
  returning id into v_po_item;

  insert into public.goods_receipts(purchase_order_id, received_by)
  values (v_po, v_user)
  returning id into v_receipt;

  insert into public.goods_receipt_items(goods_receipt_id, purchase_order_item_id, quantity_received, accepted_quantity)
  values (v_receipt, v_po_item, 2, 2)
  returning id into v_receipt_item;

  insert into public.supplier_invoices(invoice_number, supplier_id, purchase_order_id, project_id, invoice_date, created_by, subtotal, tax_amount, total_amount)
  values ('SMOKE-' || replace(gen_random_uuid()::text, '-', ''), v_supplier, v_po, v_project, current_date, v_user, 200, 30, 230)
  returning id into v_invoice;

  insert into public.supplier_invoice_lines(supplier_invoice_id, purchase_order_item_id, goods_receipt_item_id, description, quantity, unit_price, tax_amount)
  values (v_invoice, v_po_item, v_receipt_item, 'Smoke material', 2, 100, 30);

  if (select estimated_total from public.purchase_request_items where id=v_pr_item) <> 200 then
    raise exception 'Estimated total generation failed';
  end if;

  if (select line_total from public.purchase_order_items where id=v_po_item) <> 230 then
    raise exception 'Purchase order line total generation failed';
  end if;
END $$;

rollback;
