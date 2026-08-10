-- UAT-002: one approved Actual Cost source across project surfaces.
-- Additive/backward-compatible: projects.actual_cost remains a cache and no history is rewritten.
begin;

create or replace function private.project_approved_actual_cost(target_project uuid)
returns numeric
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(sum(entry.amount), 0)::numeric
  from public.project_actual_cost_entries entry
  where entry.project_id = target_project
    and entry.status = 'approved'
$$;

revoke all on function private.project_approved_actual_cost(uuid) from public, anon, authenticated;

create or replace function public.refresh_project_actual_cost(target_project uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Active authentication required';
  end if;
  perform set_config('app.project_workspace_rpc', 'on', true);
  update public.projects
  set actual_cost = private.project_approved_actual_cost(target_project), updated_at = now()
  where id = target_project;
end
$$;

revoke all on function public.refresh_project_actual_cost(uuid) from public, anon;
grant execute on function public.refresh_project_actual_cost(uuid) to authenticated;

create or replace function public.get_projects_visible()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when private.project_has_permission('project_financials_view') then
      to_jsonb(p) || jsonb_build_object(
        'actual_cost', canonical.actual_cost,
        'profit', coalesce(p.revenue, 0) - canonical.actual_cost
      )
    else (to_jsonb(p) - array['expected_cost', 'actual_cost', 'revenue', 'profit'])
  end
  from public.projects p
  cross join lateral (
    select private.project_approved_actual_cost(p.id) actual_cost
  ) canonical
  where private.project_can_view(p.id)
  order by p.created_at
$$;

revoke all on function public.get_projects_visible() from public, anon;
grant execute on function public.get_projects_visible() to authenticated;

create or replace function public.get_project_actual_cost_reconciliation()
returns setof jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'project_id', p.id,
    'project_code', p.project_code,
    'cached_actual_cost', coalesce(p.actual_cost, 0),
    'canonical_actual_cost', canonical.actual_cost,
    'difference', coalesce(p.actual_cost, 0) - canonical.actual_cost
  )
  from public.projects p
  cross join lateral (
    select private.project_approved_actual_cost(p.id) actual_cost
  ) canonical
  where private.project_has_permission('project_financials_view')
    and private.project_can_view(p.id)
    and coalesce(p.actual_cost, 0) is distinct from canonical.actual_cost
  order by p.project_code
$$;

revoke all on function public.get_project_actual_cost_reconciliation() from public, anon;
grant execute on function public.get_project_actual_cost_reconciliation() to authenticated;

create or replace function public.get_project_cost_variance_snapshot_canonical(target_project uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with source as (
    select public.get_project_cost_variance_snapshot(target_project) snapshot,
           private.project_approved_actual_cost(target_project) actual_cost
  ), canonical_values as (
    select snapshot, actual_cost,
           coalesce((snapshot->>'estimated_cost')::numeric, 0) estimated_cost,
           coalesce((snapshot->>'revenue')::numeric, 0) revenue,
           coalesce((snapshot->>'progress_percentage')::numeric, 0) progress_percentage
    from source
  )
  select case when snapshot is null then null else snapshot || jsonb_build_object(
    'actual_cost', actual_cost,
    'remaining_budget', estimated_cost-actual_cost,
    'variance', actual_cost-estimated_cost,
    'variance_percentage', case when estimated_cost=0 then null else round(((actual_cost-estimated_cost)/estimated_cost)*100,2) end,
    'gross_profit', revenue-actual_cost,
    'gross_margin_percentage', case when revenue=0 then null else round(((revenue-actual_cost)/revenue)*100,2) end,
    'forecast_final_cost', case when progress_percentage>0 then round(actual_cost/(progress_percentage/100),2) else actual_cost end,
    'forecast_profit', revenue-(case when progress_percentage>0 then round(actual_cost/(progress_percentage/100),2) else actual_cost end)
  ) end
  from canonical_values
$$;

revoke all on function public.get_project_cost_variance_snapshot_canonical(uuid) from public, anon;
grant execute on function public.get_project_cost_variance_snapshot_canonical(uuid) to authenticated;

comment on function private.project_approved_actual_cost(uuid) is
  'Canonical project Actual Cost: approved project_actual_cost_entries only. Draft, submitted, rejected and reversed rows are excluded.';
comment on function public.get_project_actual_cost_reconciliation() is
  'Read-only mismatch report between the legacy projects.actual_cost cache and the canonical approved aggregate.';
comment on function public.get_project_cost_variance_snapshot_canonical(uuid) is
  'Variance snapshot whose totals and forecasts always use approved project_actual_cost_entries.';

commit;
