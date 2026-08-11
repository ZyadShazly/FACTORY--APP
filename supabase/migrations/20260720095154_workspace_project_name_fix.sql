begin;

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
    'orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select o.*,p.name product_name,p.sku product_sku,pr.project_name
      from public.production_orders o
      left join public.products p on p.id=o.product_id
      left join public.projects pr on pr.id=o.project_id
    ) x),'[]'::jsonb),
    'operations',coalesce((select jsonb_agg(to_jsonb(x) order by x.production_order_id,x.sequence_no) from public.production_order_operations x),'[]'::jsonb),
    'requirements',coalesce((select jsonb_agg(to_jsonb(x) order by x.production_order_id,x.created_at) from (
      select r.*,i.name inventory_item_name,i.unit inventory_item_unit,w.name warehouse_name
      from public.production_material_requirements r
      join public.inventory_items i on i.id=r.inventory_item_id
      join public.inventory_warehouses w on w.id=r.warehouse_id
    ) x),'[]'::jsonb),
    'capabilities',jsonb_build_object(
      'create',private.production_action_allowed('production_create'),
      'plan',private.production_action_allowed('production_plan'),
      'release',private.production_action_allowed('production_release'),
      'issue',private.production_action_allowed('production_material_issue'),
      'operate',private.production_action_allowed('production_operation_update'),
      'complete',private.production_action_allowed('production_complete'),
      'cancel',public.current_identity_role()='owner'
    )
  );
end $$;

revoke all on function public.get_production_workspace() from public,anon;
grant execute on function public.get_production_workspace() to authenticated;

commit;