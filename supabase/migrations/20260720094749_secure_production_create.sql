begin;

create or replace function public.create_production_order_secure(
  target_product uuid,
  target_quantity numeric,
  target_waste_percentage numeric default 0,
  target_project uuid default null,
  target_warehouse uuid default null,
  target_order_date date default current_date,
  target_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  actor uuid:=auth.uid();
  product_row public.products%rowtype;
  saved public.production_orders%rowtype;
  bom_row jsonb;
  item_id uuid;
  required_qty numeric;
  materials_total numeric:=0;
begin
  if not private.production_action_allowed('production_create') then
    raise exception using errcode='42501', message='Production create access required';
  end if;
  if target_quantity is null or target_quantity<=0 then raise exception 'Positive production quantity required'; end if;
  if coalesce(target_waste_percentage,0)<0 then raise exception 'Waste percentage cannot be negative'; end if;
  select * into product_row from public.products where id=target_product;
  if not found then raise exception 'Product not found'; end if;
  if jsonb_array_length(coalesce(product_row.bom,'[]'::jsonb))>0 and target_warehouse is null then
    raise exception 'Warehouse is required for product materials';
  end if;

  insert into public.production_orders(product_id,project_id,qty,waste_percentage,materials_cost,labor_cost,overhead_cost,total_cost,unit_cost,order_date,note,status)
  values(target_product,target_project,target_quantity,coalesce(target_waste_percentage,0),0,coalesce(product_row.labor_cost,0)*target_quantity,coalesce(product_row.overhead_cost,0)*target_quantity,0,0,coalesce(target_order_date,current_date),target_note,'draft')
  returning * into saved;

  for bom_row in select value from jsonb_array_elements(coalesce(product_row.bom,'[]'::jsonb)) loop
    select id into item_id from public.inventory_items where material_id=(bom_row->>'material_id')::uuid and active limit 1;
    if item_id is null then raise exception 'BOM material is not linked to an active inventory item'; end if;
    required_qty:=(bom_row->>'qty')::numeric*target_quantity*(1+coalesce(target_waste_percentage,0)/100);
    insert into public.production_material_requirements(production_order_id,inventory_item_id,warehouse_id,required_quantity,created_by,note)
    values(saved.id,item_id,target_warehouse,required_qty,actor,'Generated from product BOM');
    materials_total:=materials_total+coalesce((select required_qty*m.unit_cost from public.materials m where m.id=(bom_row->>'material_id')::uuid),0);
  end loop;

  insert into public.production_order_operations(production_order_id,sequence_no,name,status,created_by)
  values(saved.id,1,'التنفيذ','pending',actor);

  update public.production_orders
  set materials_cost=materials_total,
      total_cost=materials_total+coalesce(product_row.labor_cost,0)*target_quantity+coalesce(product_row.overhead_cost,0)*target_quantity,
      unit_cost=(materials_total+coalesce(product_row.labor_cost,0)*target_quantity+coalesce(product_row.overhead_cost,0)*target_quantity)/target_quantity
  where id=saved.id returning * into saved;
  return to_jsonb(saved);
end $$;

revoke all on function public.create_production_order_secure(uuid,numeric,numeric,uuid,uuid,date,text) from public,anon;
grant execute on function public.create_production_order_secure(uuid,numeric,numeric,uuid,uuid,date,text) to authenticated;

commit;