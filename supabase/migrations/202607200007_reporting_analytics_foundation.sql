begin;

create or replace function public.get_reporting_workspace(
  date_from date default (date_trunc('month', current_date)::date - interval '11 months')::date,
  date_to date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  role_name text := public.current_identity_role();
  from_date date := coalesce(date_from, (date_trunc('month', current_date)::date - interval '11 months')::date);
  to_date date := coalesce(date_to, current_date);
  currency_row public.system_settings%rowtype;
begin
  if actor is null or role_name not in ('owner', 'manager', 'accountant') then
    raise exception using errcode = '42501', message = 'Financial reporting access required';
  end if;
  if from_date > to_date then
    raise exception using errcode = '22007', message = 'Invalid reporting date range';
  end if;

  select * into currency_row from public.system_settings where id = true;

  return jsonb_build_object(
    'period', jsonb_build_object('from', from_date, 'to', to_date),
    'currency', jsonb_build_object(
      'code', coalesce(currency_row.currency_code, 'SAR'),
      'symbol', coalesce(currency_row.currency_symbol, 'ر.س'),
      'locale', coalesce(currency_row.currency_locale, 'ar-SA'),
      'decimal_places', coalesce(currency_row.decimal_places, 2)
    ),
    'summary', jsonb_build_object(
      'projects_total', (select count(*) from public.projects),
      'projects_active', (select count(*) from public.projects where lifecycle in ('planning','ready_for_activation','active','on_hold')),
      'projects_delayed', (select count(*) from public.projects where lifecycle not in ('completed','closed','cancelled') and delivery_date is not null and delivery_date < current_date),
      'approved_budget', coalesce((select sum(expected_total_cost) from public.project_budget_versions where status = 'approved'), 0),
      'approved_actual_cost', coalesce((select sum(amount) from public.project_actual_cost_entries where status = 'approved' and cost_date between from_date and to_date), 0),
      'project_revenue', coalesce((select sum(revenue) from public.projects), 0),
      'inventory_quantity', coalesce((select sum(quantity_on_hand) from public.inventory_balances), 0),
      'inventory_value', coalesce((select sum(inventory_value) from public.inventory_balances), 0),
      'purchase_requests_pending', (select count(*) from public.purchase_requests where status in ('submitted','approved')),
      'purchase_orders_open', (select count(*) from public.purchase_orders where status in ('submitted','approved','sent','partially_received')),
      'supplier_invoices_due', (select count(*) from public.supplier_invoices where status in ('submitted','matched','approved') and coalesce(due_date, invoice_date) <= current_date),
      'production_orders_open', (select count(*) from public.production_orders where status in ('draft','planned','released','in_progress')),
      'production_operations_blocked', (select count(*) from public.production_order_operations where status in ('pending','ready','in_progress')),
      'payroll_pending', (select count(*) from public.payroll where status in ('draft','approved')),
      'payroll_net', coalesce((select sum(net_salary) from public.payroll where payroll_month between date_trunc('month', from_date)::date and date_trunc('month', to_date)::date), 0),
      'custody_active', (select count(*) from public.asset_assignments where status in ('pending_receiver_confirmation','issued','partially_returned','settlement_pending')),
      'custody_overdue', (select count(*) from public.asset_assignments where status in ('issued','partially_returned','settlement_pending') and expected_return_at is not null and expected_return_at < now())
    ),
    'projects', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.project_code)
      from (
        select
          p.id,
          p.project_code,
          p.project_name,
          p.lifecycle,
          p.execution_stage,
          p.effective_progress_percentage progress_percentage,
          p.delivery_date,
          p.revenue,
          coalesce(b.expected_total_cost, 0) approved_budget,
          coalesce(c.actual_cost, 0) approved_actual_cost,
          p.revenue - coalesce(c.actual_cost, 0) gross_profit,
          case when p.revenue > 0 then round(((p.revenue - coalesce(c.actual_cost, 0)) / p.revenue) * 100, 2) else null end margin_percentage,
          coalesce(c.actual_cost, 0) - coalesce(b.expected_total_cost, 0) cost_variance
        from public.projects p
        left join lateral (
          select expected_total_cost
          from public.project_budget_versions v
          where v.project_id = p.id and v.status = 'approved'
          order by v.version_number desc
          limit 1
        ) b on true
        left join lateral (
          select sum(e.amount) actual_cost
          from public.project_actual_cost_entries e
          where e.project_id = p.id and e.status = 'approved' and e.cost_date <= to_date
        ) c on true
      ) x
    ), '[]'::jsonb),
    'actual_cost_by_month', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.period_month)
      from (
        select date_trunc('month', cost_date)::date as period_month, sum(amount) amount
        from public.project_actual_cost_entries
        where status = 'approved' and cost_date between from_date and to_date
        group by 1
      ) x
    ), '[]'::jsonb),
    'actual_cost_by_category', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.amount desc)
      from (
        select cost_category category, sum(amount) amount
        from public.project_actual_cost_entries
        where status = 'approved' and cost_date between from_date and to_date
        group by cost_category
      ) x
    ), '[]'::jsonb),
    'procurement', jsonb_build_object(
      'orders_total', coalesce((select sum(total_amount) from public.purchase_orders where order_date between from_date and to_date and status <> 'cancelled'), 0),
      'invoices_total', coalesce((select sum(total_amount) from public.supplier_invoices where invoice_date between from_date and to_date and status in ('approved','paid')), 0),
      'tax_total', coalesce((select sum(tax_amount) from public.supplier_invoices where invoice_date between from_date and to_date and status in ('approved','paid')), 0),
      'unmatched_invoices', (select count(*) from public.supplier_invoices where status not in ('cancelled','reversed') and match_status <> 'matched')
    ),
    'generated_at', now()
  );
end $$;

revoke all on function public.get_reporting_workspace(date, date) from public, anon;
grant execute on function public.get_reporting_workspace(date, date) to authenticated;

comment on function public.get_reporting_workspace(date, date) is
'Protected reporting read model. Owner, manager, and accountant only; derives KPIs from canonical operational tables without copying data.';

commit;
