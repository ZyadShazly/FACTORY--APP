-- Supplier invoice three-way-match and Actual Cost accounting hardening.
begin;
create or replace function public.approve_supplier_invoice(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); inv public.supplier_invoices%rowtype; item jsonb; line_id uuid; entry jsonb; po public.purchase_orders%rowtype; po_item public.purchase_order_items%rowtype; received numeric; line_total_value numeric; qty_variance boolean:=false; price_variance boolean:=false;
begin
 if public.current_identity_role() not in('owner','manager') then raise exception 'Owner or manager role required'; end if;
 select * into po from public.purchase_orders where id=(payload->>'purchase_order_id')::uuid for update;
 if not found or po.status not in('fully_received','partially_received') then raise exception 'Received purchase order required'; end if;
 insert into public.supplier_invoices(invoice_number,supplier_id,purchase_order_id,project_id,invoice_date,due_date,currency,status,notes,created_by)
 values(payload->>'invoice_number',po.supplier_id,po.id,po.project_id,(payload->>'invoice_date')::date,nullif(payload->>'due_date','')::date,po.currency,'submitted',payload->>'notes',actor) returning * into inv;
 for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  select * into po_item from public.purchase_order_items where id=(item->>'purchase_order_item_id')::uuid and purchase_order_id=po.id;
  if not found then raise exception 'Invoice line purchase order mismatch'; end if;
  select coalesce(sum(gri.accepted_quantity),0) into received from public.goods_receipt_items gri join public.goods_receipts gr on gr.id=gri.goods_receipt_id where gr.purchase_order_id=po.id and gr.status='confirmed' and gri.purchase_order_item_id=po_item.id;
  if (item->>'quantity')::numeric>received then qty_variance:=true; end if;
  if (item->>'unit_price')::numeric<>po_item.unit_price then price_variance:=true; end if;
  line_total_value:=round(((item->>'quantity')::numeric*(item->>'unit_price')::numeric)-coalesce((item->>'discount_amount')::numeric,0)+coalesce((item->>'tax_amount')::numeric,0),2);
  if line_total_value<0 then raise exception 'Invoice line total cannot be negative'; end if;
  insert into public.supplier_invoice_lines(supplier_invoice_id,purchase_order_item_id,goods_receipt_item_id,description,quantity,unit_price,discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference)
  values(inv.id,po_item.id,nullif(item->>'goods_receipt_item_id','')::uuid,item->>'description',(item->>'quantity')::numeric,(item->>'unit_price')::numeric,coalesce((item->>'discount_amount')::numeric,0),coalesce((item->>'tax_amount')::numeric,0),coalesce(nullif(item->>'budget_item_id','')::uuid,po_item.budget_item_id),coalesce(nullif(item->>'milestone_id','')::uuid,po_item.milestone_id),coalesce(item->>'cost_center_reference',po_item.cost_center_reference)) returning id into line_id;
  entry:=public.save_project_actual_cost(jsonb_build_object('project_id',po.project_id,'cost_category','purchase_invoice','source_type','purchase_invoice_line','source_id',line_id,'source_line_reference','main','source_revision',1,'source_reference_key','purchase_invoice_line:'||line_id::text||':main:1','description',item->>'description','quantity',1,'unit','سطر فاتورة','unit_cost',line_total_value,'cost_date',(payload->>'invoice_date')::date,'budget_item_id',coalesce(nullif(item->>'budget_item_id','')::uuid,po_item.budget_item_id),'milestone_id',coalesce(nullif(item->>'milestone_id','')::uuid,po_item.milestone_id),'metadata',jsonb_build_object('supplier_invoice_id',inv.id,'po_item_id',po_item.id,'net_line_total',line_total_value)));
  perform public.submit_project_actual_cost((entry->>'id')::uuid);
  perform public.approve_project_actual_cost((entry->>'id')::uuid);
  update public.supplier_invoice_lines set actual_cost_entry_id=(entry->>'id')::uuid where id=line_id;
 end loop;
 if not exists(select 1 from public.supplier_invoice_lines where supplier_invoice_id=inv.id) then raise exception 'Invoice lines required'; end if;
 update public.supplier_invoices s set subtotal=x.subtotal,discount_amount=x.discount_amount,tax_amount=x.tax_amount,total_amount=x.total_amount,status='approved',match_status=case when qty_variance and price_variance then 'both_variance' when qty_variance then 'quantity_variance' when price_variance then 'price_variance' else 'matched' end,approved_by=actor,approved_at=now(),updated_at=now() from(select coalesce(sum(quantity*unit_price),0) subtotal,coalesce(sum(discount_amount),0) discount_amount,coalesce(sum(tax_amount),0) tax_amount,coalesce(sum(line_total),0) total_amount from public.supplier_invoice_lines where supplier_invoice_id=inv.id)x where s.id=inv.id returning s.* into inv;
 update public.purchase_orders set status='invoiced',updated_at=now() where id=po.id;
 return to_jsonb(inv);
end $$;
revoke all on function public.approve_supplier_invoice(jsonb) from public,anon;
grant execute on function public.approve_supplier_invoice(jsonb) to authenticated;
commit;