-- Post one immutable finished-goods receipt when a production order is completed.
begin;

alter table public.inventory_items
  add column if not exists product_id uuid references public.products(id) on delete restrict;

create unique index if not exists inventory_items_product_once_idx
  on public.inventory_items(product_id)
  where product_id is not null;

create index if not exists inventory_items_product_fk_idx
  on public.inventory_items(product_id)
  where product_id is not null;

alter table public.inventory_movements
  add column if not exists production_order_id uuid references public.production_orders(id) on delete restrict;

create unique index if not exists inventory_production_receipt_once_idx
  on public.inventory_movements(production_order_id)
  where movement_type='production_receipt' and production_order_id is not null;

create index if not exists inventory_movements_production_order_idx
  on public.inventory_movements(production_order_id)
  where production_order_id is not null;

alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check,
  drop constraint if exists inventory_movements_direction_check,
  drop constraint if exists inventory_movements_check2;

alter table public.inventory_movements
  add constraint inventory_movements_movement_type_check check (
    movement_type in (
      'receipt','project_issue','production_issue','production_receipt','receipt_reversal',
      'project_issue_reversal','production_issue_reversal','adjustment_in',
      'adjustment_out','transfer_in','transfer_out','production_return',
      'waste_out','damage_out','opening_balance'
    )
  ),
  add constraint inventory_movements_direction_check check (
    (
      movement_type in (
        'receipt','production_receipt','project_issue_reversal','production_issue_reversal',
        'adjustment_in','transfer_in','production_return','opening_balance'
      ) and quantity_delta>0
    ) or (
      movement_type in (
        'project_issue','production_issue','receipt_reversal','adjustment_out',
        'transfer_out','waste_out','damage_out'
      ) and quantity_delta<0
    )
  ),
  add constraint inventory_movements_check2 check (
    (
      movement_type in (
        'receipt_reversal','project_issue_reversal','production_issue_reversal'
      ) and reversed_movement_id is not null
    ) or (
      movement_type not in (
        'receipt_reversal','project_issue_reversal','production_issue_reversal'
      ) and reversed_movement_id is null
    )
  );

create or replace function public.complete_production_order(target_order uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  saved public.production_orders%rowtype;
  product_row public.products%rowtype;
  output_item uuid;
  output_warehouse uuid;
  warehouse_count integer;
  actual_material_cost numeric:=0;
  output_unit_cost numeric:=0;
  receipt public.inventory_movements%rowtype;
begin
  if not private.production_action_allowed('production_complete') then
    raise exception using errcode='42501',message='Production completion access required';
  end if;

  select * into saved
  from public.production_orders
  where id=target_order
  for update;

  if not found then raise exception 'Production order not found'; end if;
  if saved.status='completed' then return to_jsonb(saved); end if;
  if saved.status<>'in_progress' then
    raise exception 'In-progress production order required';
  end if;

  if exists(
    select 1 from public.production_material_requirements
    where production_order_id=target_order
      and issued_quantity<required_quantity
  ) then
    raise exception 'All required materials must be issued before completion';
  end if;

  if exists(
    select 1 from public.production_order_operations
    where production_order_id=target_order
      and status not in ('completed','skipped')
  ) then
    raise exception 'All operations must be completed or skipped';
  end if;

  if exists(
    select 1 from public.production_order_operations
    where production_order_id=target_order
      and status='completed'
      and quality_status<>'approved'
  ) then
    raise exception 'All completed operations require approved quality review';
  end if;

  select min(warehouse_id),count(distinct warehouse_id)
  into output_warehouse,warehouse_count
  from public.production_material_requirements
  where production_order_id=target_order;

  if output_warehouse is null then
    raise exception 'Finished goods warehouse is required';
  end if;
  if warehouse_count<>1 then
    raise exception 'Production order materials must use one warehouse before completion';
  end if;

  select * into product_row from public.products where id=saved.product_id;
  if not found then raise exception 'Product not found'; end if;

  select id into output_item
  from public.inventory_items
  where product_id=saved.product_id and active
  limit 1
  for update;

  if output_item is null then
    select id into output_item
    from public.inventory_items
    where product_id is null
      and material_id is null
      and active
      and (
        lower(name)=lower(product_row.name)
        or (product_row.sku is not null and sku=product_row.sku)
      )
    order by case when product_row.sku is not null and sku=product_row.sku then 0 else 1 end,id
    limit 1
    for update;

    if output_item is not null then
      update public.inventory_items
      set product_id=saved.product_id
      where id=output_item;
    else
      insert into public.inventory_items(sku,name,unit,active,product_id)
      values(
        'FG-'||replace(saved.product_id::text,'-',''),
        product_row.name,
        'وحدة',
        true,
        saved.product_id
      )
      returning id into output_item;
    end if;
  end if;

  select coalesce(sum(abs(m.quantity_delta)*m.unit_cost),0)
  into actual_material_cost
  from public.production_material_issues i
  join public.production_material_requirements r on r.id=i.requirement_id
  join public.inventory_movements m on m.id=i.inventory_movement_id
  where r.production_order_id=target_order
    and not exists(
      select 1 from public.inventory_movements rev
      where rev.reversed_movement_id=m.id
    );

  output_unit_cost:=round(
    (actual_material_cost+coalesce(saved.labor_cost,0)+coalesce(saved.overhead_cost,0))
    /nullif(saved.qty,0),
    4
  );

  insert into public.inventory_movements(
    movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,
    project_id,production_order_id,reason,posted_by,metadata
  ) values(
    'production_receipt',output_item,output_warehouse,saved.qty,output_unit_cost,
    saved.project_id,saved.id,'استلام منتج تام من أمر الإنتاج',actor,
    jsonb_build_object(
      'source','production_order_completion',
      'production_order_id',saved.id,
      'product_id',saved.product_id,
      'actual_material_cost',actual_material_cost
    )
  )
  returning * into receipt;

  update public.production_orders
  set status='completed',completed_at=now(),completed_by=actor
  where id=target_order
  returning * into saved;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,new_data,metadata
  ) values(
    'production_orders',saved.id::text,'production_order_completed',
    actor,to_jsonb(saved),jsonb_build_object(
      'finished_goods_inventory_item_id',output_item,
      'finished_goods_movement_id',receipt.id,
      'finished_goods_quantity',saved.qty,
      'finished_goods_unit_cost',output_unit_cost
    )
  );

  return jsonb_build_object(
    'order',to_jsonb(saved),
    'finished_goods_receipt',to_jsonb(receipt)
  );
end $$;

revoke all on function public.complete_production_order(uuid) from public,anon,authenticated;
grant execute on function public.complete_production_order(uuid) to authenticated;

commit;
