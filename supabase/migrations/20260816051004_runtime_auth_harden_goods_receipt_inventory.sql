create or replace function public.post_goods_receipt_to_inventory(target_goods_receipt_item uuid, target_inventory_item uuid, target_warehouse uuid, target_location uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public','private','pg_temp' as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); line record; saved public.inventory_movements%rowtype; effective_cost numeric;
begin
 if actor is null or not public.is_current_profile_active() or role_name not in ('owner','manager','accountant') then raise exception using errcode='42501',message='Inventory receiving access required'; end if;
 select gri.accepted_quantity,gr.status,poi.unit_price,poi.discount_amount,poi.quantity,poi.material_id,l.warehouse_id into line from public.goods_receipt_items gri join public.goods_receipts gr on gr.id=gri.goods_receipt_id join public.purchase_order_items poi on poi.id=gri.purchase_order_item_id left join public.inventory_locations l on l.id=target_location where gri.id=target_goods_receipt_item;
 if not found or line.status<>'confirmed' or line.accepted_quantity<=0 then raise exception 'Confirmed accepted receipt item required'; end if;
 if target_location is not null and line.warehouse_id<>target_warehouse then raise exception 'Location does not belong to warehouse'; end if;
 if not exists(select 1 from public.inventory_items i where i.id=target_inventory_item and i.active and (i.material_id is null or line.material_id is null or i.material_id=line.material_id)) then raise exception 'Inventory item does not match receipt material'; end if;
 effective_cost:=round((line.unit_price-(line.discount_amount/nullif(line.quantity,0))),4);
 insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,goods_receipt_item_id,posted_by,metadata) values('receipt',target_inventory_item,target_warehouse,target_location,line.accepted_quantity,effective_cost,target_goods_receipt_item,actor,jsonb_build_object('source','procurement_receipt')) returning * into saved;
 return to_jsonb(saved);
end $$;

create or replace function public.confirm_goods_receipt_to_inventory(payload jsonb, target_warehouse uuid, target_location uuid default null)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare receipt jsonb; receipt_id uuid; line record; target_item uuid; movement jsonb; movements jsonb:='[]'::jsonb; missing_material text;
begin
 if auth.uid() is null or public.current_identity_role() not in ('owner','manager','accountant') or not public.is_current_profile_active() then raise exception using errcode='42501',message='Receiving access required'; end if;
 if target_warehouse is null or not exists(select 1 from public.inventory_warehouses where id=target_warehouse and active) then raise exception using errcode='23514',message='Active warehouse required'; end if;
 if target_location is not null and not exists(select 1 from public.inventory_locations where id=target_location and warehouse_id=target_warehouse and active) then raise exception using errcode='23514',message='Active warehouse location required'; end if;
 select coalesce(material.name,order_item.description) into missing_material from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) item join public.purchase_order_items order_item on order_item.id=(item->>'purchase_order_item_id')::uuid left join public.materials material on material.id=order_item.material_id left join public.inventory_items inventory_item on inventory_item.material_id=order_item.material_id and inventory_item.active where coalesce((item->>'accepted_quantity')::numeric,(item->>'quantity_received')::numeric)>0 and (order_item.material_id is null or inventory_item.id is null) order by order_item.sequence limit 1;
 if missing_material is not null then raise exception 'يجب ربط المادة "%" بصنف مخزون نشط قبل تأكيد الاستلام',missing_material; end if;
 receipt:=public.confirm_goods_receipt(payload); receipt_id:=(receipt->>'id')::uuid;
 for line in select receipt_item.id receipt_item_id,order_item.material_id from public.goods_receipt_items receipt_item join public.purchase_order_items order_item on order_item.id=receipt_item.purchase_order_item_id where receipt_item.goods_receipt_id=receipt_id and receipt_item.accepted_quantity>0 order by receipt_item.id loop
   select inventory_item.id into target_item from public.inventory_items inventory_item where inventory_item.material_id=line.material_id and inventory_item.active order by inventory_item.created_at limit 1;
   movement:=public.post_goods_receipt_to_inventory(line.receipt_item_id,target_item,target_warehouse,target_location); movements:=movements||jsonb_build_array(movement);
 end loop;
 return jsonb_build_object('receipt',receipt,'inventory_movements',movements,'inventory_posted',jsonb_array_length(movements)>0);
end $$;