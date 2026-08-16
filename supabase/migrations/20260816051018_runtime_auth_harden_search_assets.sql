create or replace function public.search_workspace(search_term text, limit_count integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); q text:=trim(coalesce(search_term,''));
  safe_limit integer:=greatest(1,least(coalesce(limit_count,20),50)); actor_employee uuid;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') or not public.is_current_profile_active() then raise exception using errcode='42501',message='Active account required'; end if;
  if length(q)<2 then return jsonb_build_object('items','[]'::jsonb); end if;
  q:=left(q,100);
  select profile.employee_id into actor_employee from public.profiles profile where profile.id=actor;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(to_jsonb(item) order by item.rank_order,item.title)
    from (
      select * from (
        select 1 rank_order,'project' kind,project.id reference_id,'projects' page_id,coalesce(project.project_name,project.project_code) title,project.project_code subtitle
        from public.projects project
        where private.project_can_view(project.id) and (project.project_name ilike '%'||q||'%' or project.project_code ilike '%'||q||'%')
        union all
        select 2,'production_order',production_order.id,'production',coalesce(product.name,'أمر إنتاج'),'الكمية '||production_order.qty::text||' — '||production_order.status
        from public.production_orders production_order left join public.products product on product.id=production_order.product_id
        where (coalesce(product.name,'') ilike '%'||q||'%' or production_order.id::text ilike '%'||q||'%') and (role_name in ('owner','manager') or (role_name='production' and exists(select 1 from public.production_order_operations operation where operation.production_order_id=production_order.id and operation.assigned_employee_id=actor_employee)))
        union all
        select 3,'asset',asset.id,'assets',asset.name,coalesce(asset.asset_code,asset.serial_number,'')
        from public.assets asset
        where role_name in ('owner','manager') and (asset.name ilike '%'||q||'%' or coalesce(asset.asset_code,'') ilike '%'||q||'%' or coalesce(asset.serial_number,'') ilike '%'||q||'%')
        union all
        select 4,'customer',customer.id,'customers',customer.name,coalesce(customer.phone,'') from public.customers customer where role_name in ('owner','manager','accountant') and (customer.name ilike '%'||q||'%' or coalesce(customer.phone,'') ilike '%'||q||'%')
        union all
        select 5,'employee',employee.id,'employees',employee.full_name,coalesce(employee.job_title,'') from public.employees employee where role_name in ('owner','manager','accountant') and employee.status='active' and (employee.full_name ilike '%'||q||'%' or coalesce(employee.job_title,'') ilike '%'||q||'%')
        union all
        select 6,'purchase_order',purchase_order.id,'purchases',purchase_order.order_number,purchase_order.status from public.purchase_orders purchase_order where role_name in ('owner','manager','accountant') and purchase_order.order_number ilike '%'||q||'%'
      ) candidates limit safe_limit
    ) item
  ),'[]'::jsonb));
end $$;