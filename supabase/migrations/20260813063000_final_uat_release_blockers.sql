-- Final UAT blocker remediation after PR #121.
-- SEC-01, FIN-01, PAY-01, PROC-01, PROD-01.

create or replace function private.production_action_allowed(requested_action text)
returns boolean
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  actor uuid := (select auth.uid());
  profile_role text;
  profile_permissions jsonb;
  explicit_value text;
begin
  if actor is null then return false; end if;
  select p.role, p.permissions into profile_role, profile_permissions
  from public.profiles p
  where p.id=actor and coalesce(p.status,'active')='active';
  if not found then return false; end if;

  if profile_role in ('owner','manager') then return true; end if;

  explicit_value := profile_permissions->>requested_action;
  if explicit_value is not null then return explicit_value::boolean; end if;

  if profile_role='accountant' then
    return requested_action='production_view';
  end if;

  if profile_role='production' then
    return requested_action in ('production_view','production_operation_update');
  end if;

  return false;
end
$$;

create or replace function public.get_assets_visible()
returns setof jsonb
language plpgsql
stable
security definer
set search_path='public','pg_temp'
as $$
begin
  if auth.uid() is null or not public.is_current_profile_active() or not public.has_permission('assets_view') then
    raise exception using errcode='42501', message='Assets view permission required';
  end if;

  return query
  select case
    when public.current_identity_role() in ('owner','manager') or public.has_permission('assets_reports')
      then to_jsonb(a)
    else to_jsonb(a)-array['purchase_cost','supplier_id']
  end
  from public.assets a
  order by a.created_at;
end
$$;

grant execute on function public.get_assets_visible() to authenticated;

create or replace function public.get_audit_log_visible()
returns setof jsonb
language plpgsql
stable
security definer
set search_path='public','pg_temp'
as $$
begin
  if auth.uid() is null or not public.is_current_profile_active()
     or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501', message='Audit log access requires owner or manager role';
  end if;

  return query
  select to_jsonb(a) || jsonb_build_object(
    'actor', case when p.id is null then null else jsonb_build_object('full_name',p.full_name,'email',p.email) end
  )
  from public.audit_log a
  left join public.profiles p on p.id=a.actor_id
  order by a.created_at;
end
$$;

revoke select on public.audit_log from anon, authenticated;
grant execute on function public.get_audit_log_visible() to authenticated;

create or replace function public.get_payroll_review_snapshot(target_payroll_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  actor_id uuid := auth.uid();
  payroll_row public.payroll%rowtype;
  employee_name text;
  blockers jsonb;
begin
  if actor_id is null or not public.has_permission('payroll_view') then
    raise exception using errcode='42501', message='Payroll view permission required';
  end if;

  select p.* into payroll_row
  from public.payroll p
  where p.id=target_payroll_id;
  if not found then raise exception using errcode='P0002', message='Payroll record was not found'; end if;

  select e.full_name into employee_name
  from public.employees e
  where e.id=payroll_row.employee_id;

  blockers := private.payroll_review_blockers(target_payroll_id);
  return jsonb_build_object(
    'ok', true,
    'payroll', to_jsonb(payroll_row) || jsonb_build_object('employee_name', employee_name),
    'review_ready', jsonb_array_length(blockers)=0,
    'blockers', blockers,
    'sources', jsonb_build_object(
      'salary_snapshot','نسخة بيانات الموظف المحفوظة في مسير الشهر',
      'work_calendar','تقويم العمل المعتمد وإصداره المحفوظ',
      'attendance',coalesce(payroll_row.attendance_source,'لم يسجل بعد'),
      'review_inputs','إدخال المراجع مع سبب إلزامي عند وجود قيمة',
      'formula','معادلة صافي الراتب الحالية المحفوظة في قاعدة البيانات'
    )
  );
end
$$;

create or replace function public.prepare_operational_source_actual_cost(target_source_type text, target_source_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid := auth.uid();
  role_name text := public.current_identity_role();
  p_project uuid;
  p_amount numeric;
  p_date date;
  p_description text;
  p_category text;
  p_source_category text;
  p_quantity numeric := 1;
  p_unit text := 'وحدة';
  p_unit_cost numeric;
  existing_entry uuid;
  p_review_status text;
  p_cost_status text;
  p_gross numeric;
  p_addition numeric;
  p_deduction numeric;
  p_metadata jsonb := jsonb_build_object('operational_source',true);
  saved public.project_actual_cost_entries%rowtype;
begin
  if actor is null or not public.is_current_profile_active()
     or role_name not in ('owner','manager','accountant') then
    raise exception using errcode='42501',message='Owner, manager, or accountant role required';
  end if;

  if target_source_type='material_purchase' then
    select project_id,round(qty*unit_cost,2),coalesce(purchase_date,current_date),
           coalesce(note,'شراء خامات للمشروع'),qty,
           coalesce((select unit from public.materials where id=material_id),'وحدة'),unit_cost,
           actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.material_purchases where id=target_source_id for update;
    p_category := 'material';
  elsif target_source_type='daily_labor' then
    select project_id,net_amount,work_date,
           concat('عمالة يومية: ',worker_name,coalesce(' - '||trade,''),' - صافي التسوية'),
           1,'يوم',net_amount,actual_cost_entry_id,review_status,cost_posting_status,
           total_amount,addition_amount,deduction_amount
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,
           existing_entry,p_review_status,p_cost_status,p_gross,p_addition,p_deduction
    from public.daily_labor where id=target_source_id for update;
    if not found then raise exception using errcode='P0002',message='Daily labor shift was not found'; end if;
    if p_review_status<>'approved' then raise exception using errcode='23514',message='Daily labor shift must be approved before Actual Cost submission'; end if;
    if coalesce(p_cost_status,'not_posted')<>'not_posted' then raise exception using errcode='23514',message='Daily labor shift is already in the Actual Cost workflow'; end if;
    p_category := 'labor';
    p_metadata := p_metadata || jsonb_build_object(
      'settlement_basis','net_amount','gross_amount',p_gross,
      'addition_amount',p_addition,'deduction_amount',p_deduction
    );
  elsif target_source_type='payroll_allocation' then
    select project_id,net_salary,payroll_month,
           concat('توزيع راتب: ',coalesce((select full_name from public.employees where id=employee_id),'موظف'),' - ',to_char(payroll_month,'YYYY-MM')),
           1,'شهر',net_salary,actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_quantity,p_unit,p_unit_cost,existing_entry
    from public.payroll where id=target_source_id and status in ('approved','paid') for update;
    p_category := 'labor';
  elsif target_source_type='approved_expense' then
    select e.project_id,e.amount,e.expense_date,concat('مصروف مشروع: ',e.category),
           e.category,1,'مصروف',e.amount,e.actual_cost_entry_id
      into p_project,p_amount,p_date,p_description,p_source_category,
           p_quantity,p_unit,p_unit_cost,existing_entry
    from public.expenses e where e.id=target_source_id for update;
    p_category := case
      when lower(coalesce(p_source_category,'')) like '%نقل%'
        or lower(coalesce(p_source_category,'')) like '%transport%'
      then 'transport'
      else 'other'
    end;
  else
    raise exception using errcode='22023',message='Unsupported operational source type';
  end if;

  if p_project is null then raise exception using errcode='23514',message='Source must be linked to a project'; end if;
  if p_amount is null or p_amount<=0 then raise exception using errcode='23514',message='Source amount must be greater than zero'; end if;
  if existing_entry is not null then raise exception using errcode='23514',message='Source is already linked to an Actual Cost entry'; end if;
  if not private.project_can_view(p_project) then raise exception using errcode='42501',message='Project access denied'; end if;
  perform private.actual_cost_assert_mutable(p_project,p_date);

  perform set_config('app.operational_actual_cost','on',true);
  if target_source_type='daily_labor' then perform set_config('app.daily_labor_actual_cost','on',true); end if;

  insert into public.project_actual_cost_entries(
    project_id,cost_category,source_type,source_id,source_line_reference,source_revision,source_reference_key,
    description,quantity,unit,unit_cost,cost_date,status,submitted_by,submitted_at,created_by,updated_by,metadata
  ) values (
    p_project,p_category,target_source_type,target_source_id,'main',1,
    target_source_type||':'||target_source_id::text||':main:1',p_description,p_quantity,p_unit,p_unit_cost,p_date,
    'submitted',actor,now(),actor,actor,p_metadata
  ) returning * into saved;

  if target_source_type='material_purchase' then
    update public.material_purchases set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  elsif target_source_type='daily_labor' then
    update public.daily_labor set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  elsif target_source_type='payroll_allocation' then
    update public.payroll set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  else
    update public.expenses set actual_cost_entry_id=saved.id,cost_posting_status='submitted' where id=target_source_id;
  end if;

  return to_jsonb(saved);
end
$$;

create or replace function public.approve_supplier_invoice(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  inv public.supplier_invoices%rowtype;
  item jsonb;
  line_id uuid;
  entry jsonb;
  po public.purchase_orders%rowtype;
  po_item public.purchase_order_items%rowtype;
  received numeric;
  line_total_value numeric;
  base_line_total numeric;
  qty_variance boolean:=false;
  price_variance boolean:=false;
  effective_base_currency text;
  effective_rate numeric;
  effective_rate_date date;
begin
  if public.current_identity_role() not in('owner','manager') then raise exception 'Owner or manager role required'; end if;

  select * into po from public.purchase_orders where id=(payload->>'purchase_order_id')::uuid for update;
  if not found or po.status not in('fully_received','partially_received') then raise exception 'Received purchase order required'; end if;

  effective_base_currency:=nullif(po.base_currency,'');
  effective_rate:=po.exchange_rate;
  effective_rate_date:=po.rate_date;
  if effective_base_currency is null or effective_rate is null or effective_rate_date is null then
    raise exception 'Purchase order currency contract is incomplete; repair metadata explicitly before invoice approval';
  end if;
  if effective_rate<=0 then raise exception 'A positive exchange rate is required before invoice approval'; end if;
  if po.currency=effective_base_currency and effective_rate<>1 then raise exception 'Exchange rate must equal 1 when document and base currencies match'; end if;

  insert into public.supplier_invoices(
    invoice_number,supplier_id,purchase_order_id,project_id,invoice_date,due_date,
    currency,base_currency,exchange_rate,rate_date,base_total_amount,status,notes,created_by
  ) values(
    payload->>'invoice_number',po.supplier_id,po.id,po.project_id,(payload->>'invoice_date')::date,
    nullif(payload->>'due_date','')::date,po.currency,effective_base_currency,effective_rate,effective_rate_date,
    0,'submitted',payload->>'notes',actor
  ) returning * into inv;

  for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    select * into po_item from public.purchase_order_items
    where id=(item->>'purchase_order_item_id')::uuid and purchase_order_id=po.id;
    if not found then raise exception 'Invoice line purchase order mismatch'; end if;

    select coalesce(sum(gri.accepted_quantity),0) into received
    from public.goods_receipt_items gri
    join public.goods_receipts gr on gr.id=gri.goods_receipt_id
    where gr.purchase_order_id=po.id and gr.status='confirmed' and gri.purchase_order_item_id=po_item.id;

    if (item->>'quantity')::numeric>received then qty_variance:=true; end if;
    if (item->>'unit_price')::numeric<>po_item.unit_price then price_variance:=true; end if;

    line_total_value:=round(
      ((item->>'quantity')::numeric*(item->>'unit_price')::numeric)
      -coalesce((item->>'discount_amount')::numeric,0)
      +coalesce((item->>'tax_amount')::numeric,0),2
    );
    if line_total_value<0 then raise exception 'Invoice line total cannot be negative'; end if;
    base_line_total:=round(line_total_value*effective_rate,2);

    insert into public.supplier_invoice_lines(
      supplier_invoice_id,purchase_order_item_id,goods_receipt_item_id,description,quantity,unit_price,
      discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference
    ) values(
      inv.id,po_item.id,nullif(item->>'goods_receipt_item_id','')::uuid,item->>'description',
      (item->>'quantity')::numeric,(item->>'unit_price')::numeric,
      coalesce((item->>'discount_amount')::numeric,0),coalesce((item->>'tax_amount')::numeric,0),
      coalesce(nullif(item->>'budget_item_id','')::uuid,po_item.budget_item_id),
      coalesce(nullif(item->>'milestone_id','')::uuid,po_item.milestone_id),
      coalesce(item->>'cost_center_reference',po_item.cost_center_reference)
    ) returning id into line_id;

    if po.project_id is not null then
      entry:=public.save_project_actual_cost(jsonb_build_object(
        'project_id',po.project_id,'cost_category','purchase_invoice','source_type','purchase_invoice_line',
        'source_id',line_id,'source_line_reference','main','source_revision',1,
        'source_reference_key','purchase_invoice_line:'||line_id::text||':main:1',
        'description',item->>'description','quantity',1,'unit','سطر فاتورة','unit_cost',base_line_total,
        'cost_date',(payload->>'invoice_date')::date,
        'budget_item_id',coalesce(nullif(item->>'budget_item_id','')::uuid,po_item.budget_item_id),
        'milestone_id',coalesce(nullif(item->>'milestone_id','')::uuid,po_item.milestone_id),
        'metadata',jsonb_build_object(
          'supplier_invoice_id',inv.id,'po_item_id',po_item.id,'document_amount',line_total_value,
          'document_currency',po.currency,'base_amount',base_line_total,'base_currency',effective_base_currency,
          'exchange_rate',effective_rate,'rate_date',effective_rate_date
        )
      ));
      perform public.submit_project_actual_cost((entry->>'id')::uuid);
      perform public.approve_project_actual_cost((entry->>'id')::uuid);
      update public.supplier_invoice_lines set actual_cost_entry_id=(entry->>'id')::uuid where id=line_id;
    end if;
  end loop;

  if not exists(select 1 from public.supplier_invoice_lines where supplier_invoice_id=inv.id) then
    raise exception 'Invoice lines required';
  end if;

  update public.supplier_invoices s
  set subtotal=x.subtotal,
      discount_amount=x.discount_amount,
      tax_amount=x.tax_amount,
      total_amount=x.total_amount,
      base_total_amount=round(x.total_amount*effective_rate,2),
      status='approved',
      match_status=case
        when qty_variance and price_variance then 'both_variance'
        when qty_variance then 'quantity_variance'
        when price_variance then 'price_variance'
        else 'matched'
      end,
      approved_by=actor,approved_at=now(),updated_at=now()
  from(
    select coalesce(sum(quantity*unit_price),0) subtotal,
           coalesce(sum(discount_amount),0) discount_amount,
           coalesce(sum(tax_amount),0) tax_amount,
           coalesce(sum(line_total),0) total_amount
    from public.supplier_invoice_lines where supplier_invoice_id=inv.id
  ) x
  where s.id=inv.id
  returning s.* into inv;

  update public.purchase_orders set status='invoiced',updated_at=now() where id=po.id;
  return to_jsonb(inv);
end
$$;

create or replace function private.sync_production_order_cost_from_receipt()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  material_cost numeric;
  capitalized_total numeric;
begin
  if new.movement_type<>'production_receipt' or new.production_order_id is null then return new; end if;

  material_cost := coalesce(nullif(new.metadata->>'actual_material_cost','')::numeric,0);
  capitalized_total := coalesce(
    nullif(new.metadata->>'capitalized_total_cost','')::numeric,
    round(abs(new.quantity_delta)*new.unit_cost,2)
  );

  update public.production_orders
  set materials_cost=material_cost,
      total_cost=capitalized_total,
      unit_cost=case when abs(new.quantity_delta)>0 then round(capitalized_total/abs(new.quantity_delta),4) else unit_cost end
  where id=new.production_order_id;

  return new;
end
$$;

drop trigger if exists production_receipt_sync_order_cost on public.inventory_movements;
create trigger production_receipt_sync_order_cost
after insert on public.inventory_movements
for each row
when (new.movement_type='production_receipt')
execute function private.sync_production_order_cost_from_receipt();
