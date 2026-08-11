begin;

create or replace function public.get_action_center(limit_count integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  role_name text := public.current_identity_role();
  safe_limit integer := greatest(1, least(coalesce(limit_count, 30), 100));
  actor_employee uuid;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501', message='Active account required';
  end if;
  select employee_id into actor_employee from public.profiles where id = actor and status = 'active';

  return jsonb_build_object(
    'generated_at', now(),
    'items', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.priority_rank, x.due_at nulls last, x.created_at desc)
      from (
        select * from (
          select 'project_overdue'::text kind, p.id reference_id, 'projects'::text page_id,
            ('مشروع متأخر: '||coalesce(p.project_name,p.project_code)) title,
            ('موعد التسليم '||p.delivery_date::text) detail, 'critical'::text severity,
            p.delivery_date::timestamptz due_at, p.updated_at created_at, 1 priority_rank
          from public.projects p
          where role_name in ('owner','manager','accountant')
            and p.lifecycle not in ('completed','closed','cancelled') and p.delivery_date < current_date
          union all
          select 'purchase_request_pending', r.id, 'purchases',
            ('طلب شراء ينتظر الإجراء: '||r.request_number), coalesce(r.justification,''),
            case when r.required_date < current_date then 'critical' else 'warning' end,
            r.required_date::timestamptz, r.created_at, 2
          from public.purchase_requests r
          where role_name in ('owner','manager','accountant') and r.status in ('submitted','approved')
          union all
          select 'supplier_invoice_due', i.id, 'purchases',
            ('فاتورة مورد مستحقة: '||i.invoice_number), ('الإجمالي '||i.total_amount::text||' '||i.currency),
            case when coalesce(i.due_date,i.invoice_date) < current_date then 'critical' else 'warning' end,
            coalesce(i.due_date,i.invoice_date)::timestamptz, i.created_at, 2
          from public.supplier_invoices i
          where role_name in ('owner','manager','accountant') and i.status in ('submitted','matched','approved')
            and coalesce(i.due_date,i.invoice_date) <= current_date + 7
          union all
          select 'production_order_attention', o.id, 'production',
            ('أمر إنتاج يحتاج متابعة: '||coalesce(pr.name,o.id::text)),
            ('الحالة: '||o.status||' — الكمية '||o.qty::text),
            case when o.planned_end_date < current_date then 'critical' else 'info' end,
            o.planned_end_date::timestamptz, o.created_at, 3
          from public.production_orders o left join public.products pr on pr.id=o.product_id
          where o.status in ('released','in_progress')
            and (role_name in ('owner','manager') or role_name='production')
          union all
          select 'custody_alert', a.reference_id, 'assets', a.title,
            coalesce(a.alert_type,''), a.severity, a.due_at, a.created_at, 3
          from public.asset_alerts a
          where role_name in ('owner','manager','accountant')
             or exists (select 1 from public.asset_assignments aa where aa.id=a.reference_id and (aa.receiver_profile_id=actor or aa.receiver_employee_id=actor_employee))
        ) all_items
        limit safe_limit
      ) x
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.search_workspace(search_term text, limit_count integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  role_name text := public.current_identity_role();
  q text := trim(coalesce(search_term,''));
  safe_limit integer := greatest(1, least(coalesce(limit_count,20),50));
  actor_employee uuid;
begin
  if actor is null or role_name not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501', message='Active account required';
  end if;
  if length(q) < 2 then return jsonb_build_object('items','[]'::jsonb); end if;
  q := left(q,100);
  select employee_id into actor_employee from public.profiles where id=actor and status='active';

  return jsonb_build_object('items', coalesce((
    select jsonb_agg(to_jsonb(x) order by x.rank_order, x.title)
    from (
      select * from (
        select 1 rank_order, 'project' kind, p.id reference_id, 'projects' page_id,
          coalesce(p.project_name,p.project_code) title, p.project_code subtitle
        from public.projects p
        where role_name in ('owner','manager','accountant') and (p.project_name ilike '%'||q||'%' or p.project_code ilike '%'||q||'%')
        union all
        select 2,'production_order',o.id,'production',coalesce(pr.name,'أمر إنتاج'),('الكمية '||o.qty::text||' — '||o.status)
        from public.production_orders o left join public.products pr on pr.id=o.product_id
        where (role_name in ('owner','manager','production')) and (coalesce(pr.name,'') ilike '%'||q||'%' or o.id::text ilike '%'||q||'%')
        union all
        select 3,'asset',a.id,'assets',a.name,coalesce(a.asset_code,a.serial_number,'')
        from public.assets a
        where (role_name in ('owner','manager','accountant') or exists (
          select 1 from public.asset_assignment_items ai join public.asset_assignments aa on aa.id=ai.assignment_id
          where ai.asset_id=a.id and (aa.receiver_profile_id=actor or aa.receiver_employee_id=actor_employee)
        )) and (a.name ilike '%'||q||'%' or coalesce(a.asset_code,'') ilike '%'||q||'%' or coalesce(a.serial_number,'') ilike '%'||q||'%')
        union all
        select 4,'customer',c.id,'customers',c.name,coalesce(c.phone,'') from public.customers c
        where role_name in ('owner','manager','accountant') and (c.name ilike '%'||q||'%' or coalesce(c.phone,'') ilike '%'||q||'%')
        union all
        select 5,'employee',e.id,'employees',e.full_name,coalesce(e.job_title,'') from public.employees e
        where role_name in ('owner','manager','accountant') and e.status='active' and (e.full_name ilike '%'||q||'%' or coalesce(e.job_title,'') ilike '%'||q||'%')
        union all
        select 6,'purchase_order',po.id,'purchases',po.order_number,po.status from public.purchase_orders po
        where role_name in ('owner','manager','accountant') and po.order_number ilike '%'||q||'%'
      ) search_rows limit safe_limit
    ) x
  ), '[]'::jsonb));
end $$;

revoke all on function public.get_action_center(integer) from public, anon;
revoke all on function public.search_workspace(text, integer) from public, anon;
grant execute on function public.get_action_center(integer) to authenticated;
grant execute on function public.search_workspace(text, integer) to authenticated;

comment on function public.get_action_center(integer) is 'Role-aware operational action center derived from canonical tables without copying data.';
comment on function public.search_workspace(text, integer) is 'Role-aware global search with bounded input and result count.';

commit;
