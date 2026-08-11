-- Keep Production operational reads useful while removing finance-only fields.
begin;

create or replace function private.strip_jsonb_array_fields(payload jsonb,field_names text[])
returns jsonb language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(element-field_names),'[]'::jsonb)
  from jsonb_array_elements(coalesce(payload,'[]'::jsonb)) element
$$;
revoke all on function private.strip_jsonb_array_fields(jsonb,text[]) from public,anon,authenticated;

alter function public.get_inventory_workspace() rename to get_inventory_workspace_unfiltered;
alter function public.get_production_workspace() rename to get_production_workspace_unfiltered;

revoke all on function public.get_inventory_workspace_unfiltered() from public,anon,authenticated;
revoke all on function public.get_production_workspace_unfiltered() from public,anon,authenticated;

create or replace function public.get_inventory_workspace()
returns jsonb language plpgsql security definer set search_path='' as $$
declare role_name text:=public.current_identity_role(); result jsonb;
begin
  result:=public.get_inventory_workspace_unfiltered();
  if role_name='production' then
    result:=jsonb_set(result,'{materials}',private.strip_jsonb_array_fields(result->'materials',array['unit_cost','initial_stock']));
    result:=jsonb_set(result,'{unlinked_materials}',private.strip_jsonb_array_fields(result->'unlinked_materials',array['unit_cost','initial_stock']));
    result:=jsonb_set(result,'{balances}',private.strip_jsonb_array_fields(result->'balances',array['inventory_value','average_unit_cost']));
    result:=jsonb_set(result,'{movements}',private.strip_jsonb_array_fields(result->'movements',array['unit_cost','value_delta','metadata']));
    result:=jsonb_set(result,'{opening_lines}',private.strip_jsonb_array_fields(result->'opening_lines',array['unit_cost','total_value']));
  end if;
  return result;
end
$$;

create or replace function public.get_production_workspace()
returns jsonb language plpgsql security definer set search_path='' as $$
declare role_name text:=public.current_identity_role(); result jsonb;
begin
  result:=public.get_production_workspace_unfiltered();
  if role_name='production' then
    result:=jsonb_set(result,'{orders}',private.strip_jsonb_array_fields(result->'orders',array[
      'materials_cost','labor_cost','overhead_cost','total_cost','unit_cost','actual_material_cost'
    ]));
    result:=jsonb_set(result,'{requirements}',private.strip_jsonb_array_fields(result->'requirements',array[
      'unit_cost','estimated_unit_cost','actual_cost','metadata'
    ]));
  end if;
  return result;
end
$$;

create or replace function public.get_production_reference_data(dataset text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor_employee uuid;
begin
  if auth.uid() is null or public.current_identity_role()<>'production' or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Production role required';
  end if;
  select profile.employee_id into actor_employee from public.profiles profile where profile.id=auth.uid();
  if dataset='materials' then
    return coalesce((select jsonb_agg(to_jsonb(material)-array['unit_cost','initial_stock'] order by material.created_at) from public.materials material),'[]'::jsonb);
  elsif dataset='products' then
    return coalesce((select jsonb_agg(to_jsonb(product)-array['labor_cost','overhead_cost','selling_price'] order by product.created_at) from public.products product),'[]'::jsonb);
  elsif dataset='productionOrders' then
    return coalesce((select jsonb_agg(to_jsonb(production_order)-array['materials_cost','labor_cost','overhead_cost','total_cost','unit_cost'] order by production_order.created_at)
      from public.production_orders production_order
      where exists(select 1 from public.production_order_operations operation where operation.production_order_id=production_order.id and operation.assigned_employee_id=actor_employee)
    ),'[]'::jsonb);
  end if;
  raise exception using errcode='22023',message='Unsupported production reference dataset';
end
$$;

revoke all on function public.get_inventory_workspace(),public.get_production_workspace(),public.get_production_reference_data(text) from public,anon;
grant execute on function public.get_inventory_workspace(),public.get_production_workspace(),public.get_production_reference_data(text) to authenticated;

-- Production uses the sanitized RPCs above, never direct finance-bearing rows.
drop policy if exists materials_select_all on public.materials;
drop policy if exists products_select_all on public.products;
drop policy if exists production_orders_select_all on public.production_orders;
drop policy if exists operational_materials_select on public.materials;
drop policy if exists operational_products_select on public.products;
drop policy if exists operational_production_orders_select on public.production_orders;
create policy operational_materials_select on public.materials for select to authenticated
  using(public.is_current_profile_active() and public.current_identity_role() in ('owner','manager','accountant'));
create policy operational_products_select on public.products for select to authenticated
  using(public.is_current_profile_active() and public.current_identity_role() in ('owner','manager','accountant'));
create policy operational_production_orders_select on public.production_orders for select to authenticated
  using(public.is_current_profile_active() and public.current_identity_role() in ('owner','manager','accountant'));

comment on function public.get_production_reference_data(text) is
  'Sanitized material, product, and assigned-order reference rows for Production clients; excludes financial fields.';

commit;
