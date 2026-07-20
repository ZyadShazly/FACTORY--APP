-- Atomically confirm procurement receipt and post accepted quantities to the canonical inventory ledger.
begin;

create or replace function public.confirm_goods_receipt_to_inventory(
  payload jsonb,
  target_warehouse uuid,
  target_location uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  receipt jsonb;
  receipt_id uuid;
  line record;
  target_item uuid;
  movement jsonb;
  movements jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501',message='Receiving access required';
  end if;
  if target_warehouse is null or not exists(
    select 1 from public.inventory_warehouses where id=target_warehouse and active
  ) then
    raise exception 'Active warehouse required';
  end if;
  if target_location is not null and not exists(
    select 1 from public.inventory_locations where id=target_location and warehouse_id=target_warehouse and active
  ) then
    raise exception 'Active warehouse location required';
  end if;

  receipt := public.confirm_goods_receipt(payload);
  receipt_id := (receipt->>'id')::uuid;

  for line in
    select gri.id as receipt_item_id, poi.material_id
    from public.goods_receipt_items gri
    join public.purchase_order_items poi on poi.id=gri.purchase_order_item_id
    where gri.goods_receipt_id=receipt_id and gri.accepted_quantity>0
    order by gri.id
  loop
    select i.id into target_item
    from public.inventory_items i
    where i.material_id=line.material_id and i.active
    order by i.created_at
    limit 1;
    if target_item is null then
      raise exception 'Receipt material is not linked to an active inventory item';
    end if;
    movement := public.post_goods_receipt_to_inventory(
      line.receipt_item_id,target_item,target_warehouse,target_location
    );
    movements := movements || jsonb_build_array(movement);
  end loop;

  if jsonb_array_length(movements)=0 then
    raise exception 'Receipt has no accepted inventory quantities';
  end if;

  return jsonb_build_object('receipt',receipt,'inventory_movements',movements);
end $$;

revoke all on function public.confirm_goods_receipt_to_inventory(jsonb,uuid,uuid) from public,anon;
grant execute on function public.confirm_goods_receipt_to_inventory(jsonb,uuid,uuid) to authenticated;

commit;
