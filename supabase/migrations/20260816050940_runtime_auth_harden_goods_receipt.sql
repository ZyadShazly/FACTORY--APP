create or replace function public.confirm_goods_receipt(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor uuid:=auth.uid(); po_id uuid:=(payload->>'purchase_order_id')::uuid; gr public.goods_receipts%rowtype; po public.purchase_orders%rowtype; po_item public.purchase_order_items%rowtype; item jsonb; item_id uuid; delivered numeric; accepted numeric; remaining numeric; condition_value text; line_count integer:=0;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager','accountant') or not public.is_current_profile_active() then raise exception using errcode='42501',message='Receiving access required'; end if;
  select * into po from public.purchase_orders where id=po_id for update;
  if not found or po.status not in ('approved','sent','partially_received') then raise exception using errcode='23514',message='Receivable purchase order required'; end if;
  insert into public.goods_receipts(purchase_order_id,received_by,status,supplier_delivery_reference,notes,confirmed_by,confirmed_at)
  values(po_id,actor,'confirmed',nullif(btrim(payload->>'supplier_delivery_reference'),''),nullif(btrim(payload->>'notes'),''),actor,statement_timestamp()) returning * into gr;
  for item in select value from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    item_id:=(item->>'purchase_order_item_id')::uuid; delivered:=(item->>'quantity_received')::numeric; accepted:=coalesce((item->>'accepted_quantity')::numeric,delivered); condition_value:=coalesce(nullif(item->>'condition',''),'accepted');
    if delivered is null or delivered<=0 or accepted is null or accepted<0 or accepted>delivered then raise exception using errcode='22023',message='Receipt quantities are invalid'; end if;
    if condition_value not in ('accepted','partially_rejected','rejected','damaged') then raise exception using errcode='22023',message='Receipt condition is invalid'; end if;
    if accepted=delivered and condition_value<>'accepted' then raise exception using errcode='22023',message='Accepted receipt condition is inconsistent'; end if;
    if accepted<delivered and condition_value='accepted' then raise exception using errcode='22023',message='Rejected quantity requires a rejection condition'; end if;
    select * into po_item from public.purchase_order_items where id=item_id and purchase_order_id=po_id for update;
    if not found then raise exception using errcode='23503',message='Receipt item does not belong to purchase order'; end if;
    remaining:=po_item.quantity-po_item.received_quantity; if accepted>remaining then raise exception using errcode='23514',message='Accepted quantity exceeds purchase order remainder'; end if;
    insert into public.goods_receipt_items(goods_receipt_id,purchase_order_item_id,quantity_received,accepted_quantity,condition,notes) values(gr.id,item_id,delivered,accepted,condition_value,nullif(btrim(item->>'notes'),''));
    update public.purchase_order_items set received_quantity=received_quantity+accepted where id=item_id; line_count:=line_count+1;
  end loop;
  if line_count=0 then raise exception using errcode='22023',message='Receipt items required'; end if;
  update public.purchase_orders set status=case when not exists(select 1 from public.purchase_order_items where purchase_order_id=po_id and received_quantity<quantity) then 'fully_received' else 'partially_received' end,updated_at=statement_timestamp() where id=po_id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata) values('goods_receipts',gr.id::text,'goods_receipt_confirmed',actor,to_jsonb(gr),jsonb_build_object('purchase_order_id',po_id,'line_count',line_count));
  return to_jsonb(gr);
end $$;