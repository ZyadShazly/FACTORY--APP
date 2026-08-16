create or replace function public.get_action_center(limit_count integer default 30)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); safe_limit integer:=greatest(1,least(coalesce(limit_count,30),100)); actor_employee uuid;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') or not public.is_current_profile_active() then raise exception using errcode='42501',message='Active account required'; end if;
  select profile.employee_id into actor_employee from public.profiles profile where profile.id=actor;
  return jsonb_build_object('generated_at',now(),'items',coalesce((
    select jsonb_agg(to_jsonb(item) order by item.priority_rank,item.due_at nulls last,item.created_at desc)
    from (
      select * from (
        select 'project_overdue'::text kind,project.id reference_id,'projects'::text page_id,'مشروع متأخر: '||coalesce(project.project_name,project.project_code) title,'موعد التسليم '||project.delivery_date::text detail,'critical'::text severity,project.delivery_date::timestamptz due_at,project.updated_at created_at,1 priority_rank
        from public.projects project where project.lifecycle not in ('completed','closed','cancelled') and project.delivery_date<current_date and private.project_can_view(project.id)
        union all
        select 'purchase_request_pending',request.id,'purchases','طلب شراء ينتظر الإجراء: '||request.request_number,coalesce(request.justification,''),case when request.required_date<current_date then 'critical' else 'warning' end,request.required_date::timestamptz,request.created_at,2
        from public.purchase_requests request where role_name in ('owner','manager','accountant') and request.status in ('submitted','approved')
        union all
        select 'supplier_balance_due',supplier.id,'suppliers','رصيد مورد مستحق: '||supplier.name,'الرصيد الحالي '||private.supplier_due(supplier.id)::text,case when due.earliest_due<current_date then 'critical' else 'warning' end,due.earliest_due::timestamptz,due.created_at,2
        from public.suppliers supplier join lateral (select min(coalesce(invoice.due_date,invoice.invoice_date)) earliest_due,min(invoice.created_at) created_at from public.supplier_invoices invoice where invoice.supplier_id=supplier.id and invoice.status in ('submitted','matched','approved')) due on due.earliest_due is not null
        where role_name in ('owner','manager','accountant') and private.supplier_due(supplier.id)>0 and due.earliest_due<=current_date+7
        union all
        select 'production_order_attention',production_order.id,'production','أمر إنتاج يحتاج متابعة: '||coalesce(product.name,production_order.id::text),'الحالة: '||production_order.status||' — الكمية '||production_order.qty::text,case when production_order.planned_end_date<current_date then 'critical' else 'info' end,production_order.planned_end_date::timestamptz,production_order.created_at,3
        from public.production_orders production_order left join public.products product on product.id=production_order.product_id
        where production_order.status in ('released','in_progress') and (role_name in ('owner','manager') or (role_name='production' and exists(select 1 from public.production_order_operations operation where operation.production_order_id=production_order.id and operation.assigned_employee_id=actor_employee)))
        union all
        select 'custody_alert',alert.reference_id,'assets',alert.title,coalesce(alert.alert_type,''),alert.severity,alert.due_at,alert.created_at,3
        from public.asset_alerts alert where role_name in ('owner','manager')
      ) candidates limit safe_limit
    ) item
  ),'[]'::jsonb));
end $$;