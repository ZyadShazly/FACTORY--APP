begin;

-- SEC-04: non-admin users may only read their own profile row.
drop policy if exists profiles_select_all on public.profiles;
drop policy if exists profiles_select_scoped on public.profiles;
create policy profiles_select_scoped
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
  or public.current_identity_role() in ('owner','manager')
);

-- SEC-02: procurement workspace is not available to Production.
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

create or replace function public.get_procurement_workspace_v2(target_project uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or not public.is_current_profile_active() or role_name not in ('owner','manager','accountant') then
    raise exception using errcode='42501',message='Procurement access required';
  end if;
  if target_project is not null and not private.project_can_view(target_project) then
    raise exception using errcode='42501',message='Project access denied';
  end if;
  return jsonb_build_object(
    'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.purchase_requests r where target_project is null or r.project_id=target_project),'[]'::jsonb),
    'request_items',coalesce((select jsonb_agg(to_jsonb(i) order by i.purchase_request_id,i.sequence) from public.purchase_request_items i join public.purchase_requests r on r.id=i.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
    'request_history',coalesce((select jsonb_agg(to_jsonb(h) order by h.changed_at desc) from public.purchase_request_status_history h join public.purchase_requests r on r.id=h.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
    'quotes',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from public.supplier_quotes q join public.purchase_requests r on r.id=q.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
    'quote_items',coalesce((select jsonb_agg(to_jsonb(i)) from public.supplier_quote_items i join public.supplier_quotes q on q.id=i.supplier_quote_id join public.purchase_requests r on r.id=q.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
    'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.purchase_orders o where target_project is null or o.project_id=target_project),'[]'::jsonb),
    'order_items',coalesce((select jsonb_agg(to_jsonb(i) order by i.purchase_order_id,i.sequence) from public.purchase_order_items i join public.purchase_orders o on o.id=i.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
    'order_audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from public.audit_log a join public.purchase_orders o on o.id::text=a.record_id where a.table_name='purchase_orders' and (target_project is null or o.project_id=target_project)),'[]'::jsonb),
    'receipts',coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc) from public.goods_receipts g join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
    'receipt_items',coalesce((select jsonb_agg(to_jsonb(i)) from public.goods_receipt_items i join public.goods_receipts g on g.id=i.goods_receipt_id join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
    'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.supplier_invoices i where target_project is null or i.project_id=target_project),'[]'::jsonb),
    'invoice_lines',coalesce((select jsonb_agg(to_jsonb(l)) from public.supplier_invoice_lines l join public.supplier_invoices i on i.id=l.supplier_invoice_id where target_project is null or i.project_id=target_project),'[]'::jsonb),
    'capabilities',jsonb_build_object(
      'request',true,
      'approve_request',role_name in ('owner','manager'),
      'quote',role_name in ('owner','manager','accountant'),
      'order',role_name in ('owner','manager'),
      'approve_order',role_name in ('owner','manager'),
      'send_order',role_name in ('owner','manager','accountant'),
      'receive',true,
      'invoice',role_name in ('owner','manager')
    )
  );
end
$$;

-- SEC-03: Production cannot confirm procurement receipts or post them to inventory.
create or replace function public.confirm_goods_receipt(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor uuid:=auth.uid();
  po_id uuid:=(payload->>'purchase_order_id')::uuid;
  gr public.goods_receipts%rowtype;
  po public.purchase_orders%rowtype;
  po_item public.purchase_order_items%rowtype;
  item jsonb;
  item_id uuid;
  delivered numeric;
  accepted numeric;
  remaining numeric;
  condition_value text;
  line_count integer:=0;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager','accountant') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Receiving access required';
  end if;
  select * into po from public.purchase_orders where id=po_id for update;
  if not found or po.status not in ('approved','sent','partially_received') then
    raise exception using errcode='23514',message='Receivable purchase order required';
  end if;
  insert into public.goods_receipts(purchase_order_id,received_by,status,supplier_delivery_reference,notes,confirmed_by,confirmed_at)
  values(po_id,actor,'confirmed',nullif(btrim(payload->>'supplier_delivery_reference'),''),nullif(btrim(payload->>'notes'),''),actor,statement_timestamp()) returning * into gr;
  for item in select value from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    item_id:=(item->>'purchase_order_item_id')::uuid;
    delivered:=(item->>'quantity_received')::numeric;
    accepted:=coalesce((item->>'accepted_quantity')::numeric,delivered);
    condition_value:=coalesce(nullif(item->>'condition',''),'accepted');
    if delivered is null or delivered<=0 or accepted is null or accepted<0 or accepted>delivered then
      raise exception using errcode='22023',message='Receipt quantities are invalid';
    end if;
    if condition_value not in ('accepted','partially_rejected','rejected','damaged') then
      raise exception using errcode='22023',message='Receipt condition is invalid';
    end if;
    if accepted=delivered and condition_value<>'accepted' then
      raise exception using errcode='22023',message='Accepted receipt condition is inconsistent';
    end if;
    if accepted<delivered and condition_value='accepted' then
      raise exception using errcode='22023',message='Rejected quantity requires a rejection condition';
    end if;
    select * into po_item from public.purchase_order_items where id=item_id and purchase_order_id=po_id for update;
    if not found then raise exception using errcode='23503',message='Receipt item does not belong to purchase order'; end if;
    remaining:=po_item.quantity-po_item.received_quantity;
    if accepted>remaining then raise exception using errcode='23514',message='Accepted quantity exceeds purchase order remainder'; end if;
    insert into public.goods_receipt_items(goods_receipt_id,purchase_order_item_id,quantity_received,accepted_quantity,condition,notes)
    values(gr.id,item_id,delivered,accepted,condition_value,nullif(btrim(item->>'notes'),''));
    update public.purchase_order_items set received_quantity=received_quantity+accepted where id=item_id;
    line_count:=line_count+1;
  end loop;
  if line_count=0 then raise exception using errcode='22023',message='Receipt items required'; end if;
  update public.purchase_orders
  set status=case when not exists(select 1 from public.purchase_order_items where purchase_order_id=po_id and received_quantity<quantity) then 'fully_received' else 'partially_received' end,
      updated_at=statement_timestamp()
  where id=po_id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('goods_receipts',gr.id::text,'goods_receipt_confirmed',actor,to_jsonb(gr),jsonb_build_object('purchase_order_id',po_id,'line_count',line_count));
  return to_jsonb(gr);
end
$$;

create or replace function public.post_goods_receipt_to_inventory(target_goods_receipt_item uuid, target_inventory_item uuid, target_warehouse uuid, target_location uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','private','pg_temp'
as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); line record; saved public.inventory_movements%rowtype; effective_cost numeric;
begin
  if actor is null or not public.is_current_profile_active() or role_name not in ('owner','manager','accountant') then
    raise exception using errcode='42501',message='Inventory receiving access required';
  end if;
  select gri.accepted_quantity,gr.status,poi.unit_price,poi.discount_amount,poi.quantity,poi.material_id,l.warehouse_id into line
  from public.goods_receipt_items gri
  join public.goods_receipts gr on gr.id=gri.goods_receipt_id
  join public.purchase_order_items poi on poi.id=gri.purchase_order_item_id
  left join public.inventory_locations l on l.id=target_location
  where gri.id=target_goods_receipt_item;
  if not found or line.status<>'confirmed' or line.accepted_quantity<=0 then raise exception 'Confirmed accepted receipt item required'; end if;
  if target_location is not null and line.warehouse_id<>target_warehouse then raise exception 'Location does not belong to warehouse'; end if;
  if not exists(select 1 from public.inventory_items i where i.id=target_inventory_item and i.active and (i.material_id is null or line.material_id is null or i.material_id=line.material_id)) then raise exception 'Inventory item does not match receipt material'; end if;
  effective_cost:=round((line.unit_price-(line.discount_amount/nullif(line.quantity,0))),4);
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,goods_receipt_item_id,posted_by,metadata)
  values('receipt',target_inventory_item,target_warehouse,target_location,line.accepted_quantity,effective_cost,target_goods_receipt_item,actor,jsonb_build_object('source','procurement_receipt')) returning * into saved;
  return to_jsonb(saved);
end
$$;

create or replace function public.confirm_goods_receipt_to_inventory(payload jsonb, target_warehouse uuid, target_location uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  receipt jsonb;
  receipt_id uuid;
  line record;
  target_item uuid;
  movement jsonb;
  movements jsonb:='[]'::jsonb;
  missing_material text;
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager','accountant') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Receiving access required';
  end if;
  if target_warehouse is null or not exists(select 1 from public.inventory_warehouses where id=target_warehouse and active) then
    raise exception using errcode='23514',message='Active warehouse required';
  end if;
  if target_location is not null and not exists(select 1 from public.inventory_locations where id=target_location and warehouse_id=target_warehouse and active) then
    raise exception using errcode='23514',message='Active warehouse location required';
  end if;
  select coalesce(material.name,order_item.description) into missing_material
  from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) item
  join public.purchase_order_items order_item on order_item.id=(item->>'purchase_order_item_id')::uuid
  left join public.materials material on material.id=order_item.material_id
  left join public.inventory_items inventory_item on inventory_item.material_id=order_item.material_id and inventory_item.active
  where coalesce((item->>'accepted_quantity')::numeric,(item->>'quantity_received')::numeric)>0
    and (order_item.material_id is null or inventory_item.id is null)
  order by order_item.sequence limit 1;
  if missing_material is not null then
    raise exception 'يجب ربط المادة "%" بصنف مخزون نشط قبل تأكيد الاستلام',missing_material;
  end if;
  receipt:=public.confirm_goods_receipt(payload);
  receipt_id:=(receipt->>'id')::uuid;
  for line in
    select receipt_item.id receipt_item_id,order_item.material_id
    from public.goods_receipt_items receipt_item
    join public.purchase_order_items order_item on order_item.id=receipt_item.purchase_order_item_id
    where receipt_item.goods_receipt_id=receipt_id and receipt_item.accepted_quantity>0
    order by receipt_item.id
  loop
    select inventory_item.id into target_item
    from public.inventory_items inventory_item
    where inventory_item.material_id=line.material_id and inventory_item.active
    order by inventory_item.created_at limit 1;
    movement:=public.post_goods_receipt_to_inventory(line.receipt_item_id,target_item,target_warehouse,target_location);
    movements:=movements||jsonb_build_array(movement);
  end loop;
  return jsonb_build_object('receipt',receipt,'inventory_movements',movements,'inventory_posted',jsonb_array_length(movements)>0);
end
$$;

-- SEC-05: side-channel search and action-center asset visibility must honor assets_view.
create or replace function public.search_workspace(search_term text, limit_count integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); q text:=trim(coalesce(search_term,'')); safe_limit integer:=greatest(1,least(coalesce(limit_count,20),50)); actor_employee uuid;
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
        where public.has_permission('assets_view')
          and (role_name in ('owner','manager','accountant') or exists(select 1 from public.asset_assignment_items assignment_item join public.asset_assignments assignment on assignment.id=assignment_item.assignment_id where assignment_item.asset_id=asset.id and (assignment.receiver_profile_id=actor or assignment.receiver_employee_id=actor_employee)))
          and (asset.name ilike '%'||q||'%' or coalesce(asset.asset_code,'') ilike '%'||q||'%' or coalesce(asset.serial_number,'') ilike '%'||q||'%')
        union all
        select 4,'customer',customer.id,'customers',customer.name,coalesce(customer.phone,'') from public.customers customer where role_name in ('owner','manager','accountant') and (customer.name ilike '%'||q||'%' or coalesce(customer.phone,'') ilike '%'||q||'%')
        union all
        select 5,'employee',employee.id,'employees',employee.full_name,coalesce(employee.job_title,'') from public.employees employee where role_name in ('owner','manager','accountant') and employee.status='active' and (employee.full_name ilike '%'||q||'%' or coalesce(employee.job_title,'') ilike '%'||q||'%')
        union all
        select 6,'purchase_order',purchase_order.id,'purchases',purchase_order.order_number,purchase_order.status from public.purchase_orders purchase_order where role_name in ('owner','manager','accountant') and purchase_order.order_number ilike '%'||q||'%'
      ) candidates limit safe_limit
    ) item
  ),'[]'::jsonb));
end
$$;

create or replace function public.get_action_center(limit_count integer default 30)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); safe_limit integer:=greatest(1,least(coalesce(limit_count,30),100)); actor_employee uuid;
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
        from public.asset_alerts alert
        where public.has_permission('assets_view')
          and (role_name in ('owner','manager','accountant') or exists(select 1 from public.asset_assignments assignment where assignment.id=alert.reference_id and (assignment.receiver_profile_id=actor or assignment.receiver_employee_id=actor_employee)))
      ) candidates limit safe_limit
    ) item
  ),'[]'::jsonb));
end
$$;

-- SEC-06: derived Actual Cost refresh is only allowed to authorized project viewers with finance visibility.
create or replace function public.refresh_project_actual_cost(target_project uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Active authentication required';
  end if;
  if role_name not in ('owner','manager') and not (
    role_name='accountant'
    and private.project_can_view(target_project)
    and private.actual_cost_has_permission('project_actual_cost_view')
  ) then
    raise exception using errcode='42501',message='Project Actual Cost refresh permission required';
  end if;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects
  set actual_cost=private.project_approved_actual_cost(target_project),updated_at=now()
  where id=target_project;
  if not found then raise exception using errcode='P0002',message='Project not found'; end if;
end
$$;

commit;
