begin;

create or replace function private.production_action_allowed(requested_action text)
returns boolean
language plpgsql
stable
security definer
set search_path=public,private,pg_temp
as $$
declare
  actor uuid:=auth.uid();
  profile_row public.profiles%rowtype;
  explicit_value text;
begin
  if actor is null then return false; end if;
  select * into profile_row from public.profiles where id=actor and coalesce(status,'active')='active';
  if not found then return false; end if;
  if profile_row.role in ('owner','manager') then return true; end if;
  if profile_row.role<>'production' then return false; end if;
  explicit_value:=profile_row.permissions->>requested_action;
  if explicit_value is not null then return explicit_value::boolean; end if;
  return requested_action in ('production_view','production_create','production_plan','production_release','production_material_issue','production_operation_update','production_complete');
end $$;

create or replace function public.get_production_orders_visible()
returns setof public.production_orders
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
begin
  if not private.production_action_allowed('production_view') then
    raise exception using errcode='42501', message='Production access required';
  end if;
  return query select * from public.production_orders order by created_at asc;
end $$;

create or replace function public.get_production_workspace()
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
begin
  if not private.production_action_allowed('production_view') then
    raise exception using errcode='42501', message='Production access required';
  end if;
  return jsonb_build_object(
    'orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select o.*,p.name product_name,p.sku product_sku,pr.name project_name from public.production_orders o left join public.products p on p.id=o.product_id left join public.projects pr on pr.id=o.project_id) x),'[]'::jsonb),
    'operations',coalesce((select jsonb_agg(to_jsonb(x) order by x.production_order_id,x.sequence_no) from public.production_order_operations x),'[]'::jsonb),
    'requirements',coalesce((select jsonb_agg(to_jsonb(x) order by x.production_order_id,x.created_at) from (select r.*,i.name inventory_item_name,i.unit inventory_item_unit,w.name warehouse_name from public.production_material_requirements r join public.inventory_items i on i.id=r.inventory_item_id join public.inventory_warehouses w on w.id=r.warehouse_id) x),'[]'::jsonb),
    'capabilities',jsonb_build_object('create',private.production_action_allowed('production_create'),'plan',private.production_action_allowed('production_plan'),'release',private.production_action_allowed('production_release'),'issue',private.production_action_allowed('production_material_issue'),'operate',private.production_action_allowed('production_operation_update'),'complete',private.production_action_allowed('production_complete'),'cancel',public.current_identity_role()='owner')
  );
end $$;

create or replace function public.get_inventory_workspace()
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501', message='Inventory access required';
  end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.name) from public.inventory_items i where i.active),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(w) order by w.name) from public.inventory_warehouses w where w.active),'[]'::jsonb),
    'balances',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_name,x.warehouse_name) from (select b.*,i.name item_name,i.sku,i.unit,w.name warehouse_name,case when b.quantity_on_hand=0 then 0 else b.inventory_value/nullif(b.quantity_on_hand,0) end average_unit_cost from public.inventory_balances b join public.inventory_items i on i.id=b.inventory_item_id join public.inventory_warehouses w on w.id=b.warehouse_id) x),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.posted_at desc) from (select m.*,i.name item_name,w.name warehouse_name from public.inventory_movements m join public.inventory_items i on i.id=m.inventory_item_id join public.inventory_warehouses w on w.id=m.warehouse_id order by m.posted_at desc limit 100) x),'[]'::jsonb)
  );
end $$;

revoke all on function private.production_action_allowed(text) from public,anon,authenticated;
revoke all on function public.get_production_orders_visible() from public,anon;
revoke all on function public.get_production_workspace() from public,anon;
revoke all on function public.get_inventory_workspace() from public,anon;
grant execute on function public.get_production_orders_visible() to authenticated;
grant execute on function public.get_production_workspace() to authenticated;
grant execute on function public.get_inventory_workspace() to authenticated;

commit;