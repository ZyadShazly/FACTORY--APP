-- Inventory material catalog and receipt-linking hardening.
-- Additive only: preserves all items, links, balances, and movement history.
begin;

create or replace function public.manage_inventory_item_catalog(
  target_item uuid,
  target_material uuid,
  target_active boolean
) returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  actor uuid:=auth.uid();
  saved public.inventory_items%rowtype;
  old_row public.inventory_items%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  select * into old_row from public.inventory_items where id=target_item for update;
  if not found then raise exception 'Inventory item not found'; end if;
  if target_material is not null and not exists(select 1 from public.materials where id=target_material) then
    raise exception 'Material not found';
  end if;
  if target_active=false and old_row.active and exists(
    select 1 from public.inventory_balances b where b.inventory_item_id=target_item and b.quantity_on_hand<>0
  ) then
    raise exception 'Cannot deactivate an inventory item with stock. Transfer or adjust its balance to zero first';
  end if;
  update public.inventory_items
    set material_id=target_material,active=coalesce(target_active,active)
    where id=target_item
    returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'inventory_items',saved.id::text,'inventory_catalog_updated',actor,to_jsonb(old_row),to_jsonb(saved),
    jsonb_build_object('source','inventory_material_catalog','material_link_changed',old_row.material_id is distinct from saved.material_id,'active_changed',old_row.active is distinct from saved.active)
  );
  return to_jsonb(saved);
exception
  when unique_violation then
    raise exception 'This material is already linked to another inventory item';
end $$;

create or replace function public.get_inventory_workspace()
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then raise exception using errcode='42501',message='Inventory access required'; end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.name) from public.inventory_items i where i.active),'[]'::jsonb),
    'catalog',coalesce((select jsonb_agg(to_jsonb(x) order by x.active desc,x.name) from (
      select i.*,m.name material_name from public.inventory_items i left join public.materials m on m.id=i.material_id
    ) x),'[]'::jsonb),
    'materials',coalesce((select jsonb_agg(to_jsonb(m) order by m.name) from public.materials m),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(w) order by w.name) from public.inventory_warehouses w where w.active),'[]'::jsonb),
    'warehouse_admin',coalesce((select jsonb_agg(to_jsonb(w) order by w.active desc,w.name) from public.inventory_warehouses w),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.warehouse_id,l.name) from public.inventory_locations l where l.active),'[]'::jsonb),
    'balances',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_name,x.warehouse_name) from (select b.*,i.name item_name,i.sku,i.unit,w.name warehouse_name,case when b.quantity_on_hand=0 then 0 else b.inventory_value/nullif(b.quantity_on_hand,0) end average_unit_cost from public.inventory_balances b join public.inventory_items i on i.id=b.inventory_item_id join public.inventory_warehouses w on w.id=b.warehouse_id) x),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.posted_at desc) from (select m.*,i.name item_name,w.name warehouse_name from public.inventory_movements m join public.inventory_items i on i.id=m.inventory_item_id join public.inventory_warehouses w on w.id=m.warehouse_id order by m.posted_at desc limit 100) x),'[]'::jsonb),
    'count_sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from public.inventory_count_sessions s),'[]'::jsonb),
    'count_lines',coalesce((select jsonb_agg(to_jsonb(l) order by l.session_id,i.name) from public.inventory_count_lines l join public.inventory_items i on i.id=l.inventory_item_id),'[]'::jsonb),
    'capabilities',jsonb_build_object('manage',private.inventory_manage_allowed(),'production_event',role_name in ('owner','manager','production'),'view_financials',role_name in ('owner','manager','accountant'))
  );
end $$;

create or replace function public.confirm_goods_receipt_to_inventory(
  payload jsonb,
  target_warehouse uuid,
  target_location uuid default null
) returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
  receipt jsonb; receipt_id uuid; line record; target_item uuid; movement jsonb; movements jsonb:='[]'::jsonb;
  missing_material text;
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501',message='Receiving access required';
  end if;
  if target_warehouse is null or not exists(select 1 from public.inventory_warehouses where id=target_warehouse and active) then raise exception 'Active warehouse required'; end if;
  if target_location is not null and not exists(select 1 from public.inventory_locations where id=target_location and warehouse_id=target_warehouse and active) then raise exception 'Active warehouse location required'; end if;

  select coalesce(m.name,poi.description)
    into missing_material
  from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) p
  join public.purchase_order_items poi on poi.id=(p->>'purchase_order_item_id')::uuid
  left join public.materials m on m.id=poi.material_id
  left join public.inventory_items i on i.material_id=poi.material_id and i.active
  where coalesce((p->>'accepted_quantity')::numeric,(p->>'quantity_received')::numeric)>0
    and (poi.material_id is null or i.id is null)
  order by poi.sequence
  limit 1;
  if missing_material is not null then
    raise exception 'يجب ربط المادة "%" بصنف مخزون نشط قبل تأكيد الاستلام',missing_material;
  end if;

  receipt:=public.confirm_goods_receipt(payload);
  receipt_id:=(receipt->>'id')::uuid;
  for line in
    select gri.id receipt_item_id,poi.material_id
    from public.goods_receipt_items gri join public.purchase_order_items poi on poi.id=gri.purchase_order_item_id
    where gri.goods_receipt_id=receipt_id and gri.accepted_quantity>0 order by gri.id
  loop
    select i.id into target_item from public.inventory_items i where i.material_id=line.material_id and i.active order by i.created_at limit 1;
    movement:=public.post_goods_receipt_to_inventory(line.receipt_item_id,target_item,target_warehouse,target_location);
    movements:=movements||jsonb_build_array(movement);
  end loop;
  if jsonb_array_length(movements)=0 then raise exception 'Receipt has no accepted inventory quantities'; end if;
  return jsonb_build_object('receipt',receipt,'inventory_movements',movements);
end $$;

revoke all on function public.manage_inventory_item_catalog(uuid,uuid,boolean) from public,anon;
grant execute on function public.manage_inventory_item_catalog(uuid,uuid,boolean) to authenticated;

commit;
