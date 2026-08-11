begin;
create or replace function public.get_procurement_workspace_v2(target_project uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare role_name text:=public.current_identity_role();
begin
 if auth.uid() is null or role_name not in('owner','manager','accountant','production') then raise exception using errcode='42501',message='Procurement access required'; end if;
 if target_project is not null and not private.project_can_view(target_project) then raise exception using errcode='42501',message='Project access denied'; end if;
 return jsonb_build_object(
  'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.purchase_requests r where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'request_items',coalesce((select jsonb_agg(to_jsonb(i) order by i.purchase_request_id,i.sequence) from public.purchase_request_items i join public.purchase_requests r on r.id=i.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'quotes',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from public.supplier_quotes q join public.purchase_requests r on r.id=q.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'quote_items',coalesce((select jsonb_agg(to_jsonb(i)) from public.supplier_quote_items i join public.supplier_quotes q on q.id=i.supplier_quote_id join public.purchase_requests r on r.id=q.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.purchase_orders o where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'order_items',coalesce((select jsonb_agg(to_jsonb(i) order by i.purchase_order_id,i.sequence) from public.purchase_order_items i join public.purchase_orders o on o.id=i.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'receipts',coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc) from public.goods_receipts g join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'receipt_items',coalesce((select jsonb_agg(to_jsonb(i)) from public.goods_receipt_items i join public.goods_receipts g on g.id=i.goods_receipt_id join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.supplier_invoices i where target_project is null or i.project_id=target_project),'[]'::jsonb),
  'invoice_lines',coalesce((select jsonb_agg(to_jsonb(l)) from public.supplier_invoice_lines l join public.supplier_invoices i on i.id=l.supplier_invoice_id where target_project is null or i.project_id=target_project),'[]'::jsonb),
  'capabilities',jsonb_build_object('request',true,'approve_request',role_name in('owner','manager'),'quote',role_name in('owner','manager','accountant'),'order',role_name in('owner','manager'),'receive',true,'invoice',role_name in('owner','manager'))
 );
end $$;
revoke all on function public.get_procurement_workspace_v2(uuid) from public,anon;
grant execute on function public.get_procurement_workspace_v2(uuid) to authenticated;
commit;