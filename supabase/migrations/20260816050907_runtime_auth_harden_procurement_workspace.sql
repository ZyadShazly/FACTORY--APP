create or replace function public.get_procurement_workspace(target_project uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $$
begin
  if auth.uid() is null
     or not public.is_current_profile_active()
     or public.current_identity_role() not in ('owner','manager','accountant') then
    raise exception using errcode='42501', message='Procurement access required';
  end if;
  if target_project is not null and not private.project_can_view(target_project) then
    raise exception using errcode='42501', message='Project access denied';
  end if;
  return jsonb_build_object(
    'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.purchase_requests r where target_project is null or r.project_id=target_project),'[]'::jsonb),
    'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.purchase_orders o where target_project is null or o.project_id=target_project),'[]'::jsonb),
    'receipts',coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc) from public.goods_receipts g join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
    'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.supplier_invoices i where target_project is null or i.project_id=target_project),'[]'::jsonb)
  );
end
$$;