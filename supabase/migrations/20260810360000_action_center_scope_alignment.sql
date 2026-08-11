-- Align global search and notifications with assigned Production work and account-level supplier settlement.
begin;

create or replace function public.get_action_center(limit_count integer default 30)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  actor uuid:=auth.uid(); role_name text:=public.current_identity_role();
  safe_limit integer:=greatest(1,least(coalesce(limit_count,30),100)); actor_employee uuid;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Active account required';
  end if;
  select profile.employee_id into actor_employee from public.profiles profile where profile.id=actor;
  return jsonb_build_object('generated_at',now(),'items',coalesce((
    select jsonb_agg(to_jsonb(item) order by item.priority_rank,item.due_at nulls last,item.created_at desc)
    from (
      select * from (
        select 'project_overdue'::text kind,project.id reference_id,'projects'::text page_id,
          'مشروع متأخر: '||coalesce(project.project_name,project.project_code) title,
          'موعد التسليم '||project.delivery_date::text detail,'critical'::text severity,
          project.delivery_date::timestamptz due_at,project.updated_at created_at,1 priority_rank
        from public.projects project
        where project.lifecycle not in ('completed','closed','cancelled') and project.delivery_date<current_date
          and private.project_can_view(project.id)
        union all
        select 'purchase_request_pending',request.id,'purchases',
          'طلب شراء ينتظر الإجراء: '||request.request_number,coalesce(request.justification,''),
          case when request.required_date<current_date then 'critical' else 'warning' end,
          request.required_date::timestamptz,request.created_at,2
        from public.purchase_requests request
        where role_name in ('owner','manager','accountant') and request.status in ('submitted','approved')
        union all
        select 'supplier_balance_due',supplier.id,'suppliers',
          'رصيد مورد مستحق: '||supplier.name,
          'الرصيد الحالي '||private.supplier_due(supplier.id)::text,
          case when due.earliest_due<current_date then 'critical' else 'warning' end,
          due.earliest_due::timestamptz,due.created_at,2
        from public.suppliers supplier
        join lateral (
          select min(coalesce(invoice.due_date,invoice.invoice_date)) earliest_due,min(invoice.created_at) created_at
          from public.supplier_invoices invoice
          where invoice.supplier_id=supplier.id and invoice.status in ('submitted','matched','approved')
        ) due on due.earliest_due is not null
        where role_name in ('owner','manager','accountant') and private.supplier_due(supplier.id)>0
          and due.earliest_due<=current_date+7
        union all
        select 'production_order_attention',production_order.id,'production',
          'أمر إنتاج يحتاج متابعة: '||coalesce(product.name,production_order.id::text),
          'الحالة: '||production_order.status||' — الكمية '||production_order.qty::text,
          case when production_order.planned_end_date<current_date then 'critical' else 'info' end,
          production_order.planned_end_date::timestamptz,production_order.created_at,3
        from public.production_orders production_order
        left join public.products product on product.id=production_order.product_id
        where production_order.status in ('released','in_progress') and (
          role_name in ('owner','manager') or (role_name='production' and exists(
            select 1 from public.production_order_operations operation
            where operation.production_order_id=production_order.id and operation.assigned_employee_id=actor_employee
          ))
        )
        union all
        select 'custody_alert',alert.reference_id,'assets',alert.title,coalesce(alert.alert_type,''),alert.severity,alert.due_at,alert.created_at,3
        from public.asset_alerts alert
        where role_name in ('owner','manager','accountant') or exists(
          select 1 from public.asset_assignments assignment where assignment.id=alert.reference_id
            and (assignment.receiver_profile_id=actor or assignment.receiver_employee_id=actor_employee)
        )
      ) candidates limit safe_limit
    ) item
  ),'[]'::jsonb));
end
$$;

create or replace function public.search_workspace(search_term text,limit_count integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); q text:=trim(coalesce(search_term,''));
  safe_limit integer:=greatest(1,least(coalesce(limit_count,20),50)); actor_employee uuid;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Active account required';
  end if;
  if length(q)<2 then return jsonb_build_object('items','[]'::jsonb); end if;
  q:=left(q,100);
  select profile.employee_id into actor_employee from public.profiles profile where profile.id=actor;
  return jsonb_build_object('items',coalesce((
    select jsonb_agg(to_jsonb(item) order by item.rank_order,item.title)
    from (
      select * from (
        select 1 rank_order,'project' kind,project.id reference_id,'projects' page_id,
          coalesce(project.project_name,project.project_code) title,project.project_code subtitle
        from public.projects project
        where private.project_can_view(project.id) and (project.project_name ilike '%'||q||'%' or project.project_code ilike '%'||q||'%')
        union all
        select 2,'production_order',production_order.id,'production',coalesce(product.name,'أمر إنتاج'),'الكمية '||production_order.qty::text||' — '||production_order.status
        from public.production_orders production_order left join public.products product on product.id=production_order.product_id
        where (coalesce(product.name,'') ilike '%'||q||'%' or production_order.id::text ilike '%'||q||'%') and (
          role_name in ('owner','manager') or (role_name='production' and exists(
            select 1 from public.production_order_operations operation
            where operation.production_order_id=production_order.id and operation.assigned_employee_id=actor_employee
          ))
        )
        union all
        select 3,'asset',asset.id,'assets',asset.name,coalesce(asset.asset_code,asset.serial_number,'')
        from public.assets asset
        where (role_name in ('owner','manager','accountant') or exists(
          select 1 from public.asset_assignment_items assignment_item join public.asset_assignments assignment on assignment.id=assignment_item.assignment_id
          where assignment_item.asset_id=asset.id and (assignment.receiver_profile_id=actor or assignment.receiver_employee_id=actor_employee)
        )) and (asset.name ilike '%'||q||'%' or coalesce(asset.asset_code,'') ilike '%'||q||'%' or coalesce(asset.serial_number,'') ilike '%'||q||'%')
        union all
        select 4,'customer',customer.id,'customers',customer.name,coalesce(customer.phone,'')
        from public.customers customer where role_name in ('owner','manager','accountant')
          and (customer.name ilike '%'||q||'%' or coalesce(customer.phone,'') ilike '%'||q||'%')
        union all
        select 5,'employee',employee.id,'employees',employee.full_name,coalesce(employee.job_title,'')
        from public.employees employee where role_name in ('owner','manager','accountant') and employee.status='active'
          and (employee.full_name ilike '%'||q||'%' or coalesce(employee.job_title,'') ilike '%'||q||'%')
        union all
        select 6,'purchase_order',purchase_order.id,'purchases',purchase_order.order_number,purchase_order.status
        from public.purchase_orders purchase_order where role_name in ('owner','manager','accountant') and purchase_order.order_number ilike '%'||q||'%'
      ) candidates limit safe_limit
    ) item
  ),'[]'::jsonb));
end
$$;

revoke all on function public.get_action_center(integer),public.search_workspace(text,integer) from public,anon;
grant execute on function public.get_action_center(integer),public.search_workspace(text,integer) to authenticated;

commit;
