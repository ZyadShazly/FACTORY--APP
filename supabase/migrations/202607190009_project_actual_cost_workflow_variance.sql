-- Actual Cost workflow completion and project variance/profit snapshot.
-- Additive migration built on 202607190006..008.

begin;

create or replace function public.reject_project_actual_cost(target_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.project_actual_cost_entries%rowtype;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then
    raise exception 'Owner or manager approval role required';
  end if;
  if btrim(coalesce(reason,'')) = '' then raise exception 'Rejection reason is required'; end if;

  select * into saved from public.project_actual_cost_entries where id = target_id for update;
  if not found then raise exception 'Actual cost not found'; end if;
  if saved.status <> 'submitted' then raise exception 'Only submitted cost may be rejected'; end if;
  perform private.actual_cost_assert_mutable(saved.project_id, saved.cost_date);

  update public.project_actual_cost_entries
  set status='rejected', rejected_by=actor, rejected_at=now(), rejection_reason=btrim(reason), updated_by=actor, updated_at=now()
  where id=target_id
  returning * into saved;

  return to_jsonb(saved);
end $$;

create or replace function public.reverse_project_actual_cost(target_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.project_actual_cost_entries%rowtype;
begin
  if actor is null or public.current_identity_role() <> 'owner' then
    raise exception 'Owner role required';
  end if;
  if btrim(coalesce(reason,'')) = '' then raise exception 'Reversal reason is required'; end if;

  select * into saved from public.project_actual_cost_entries where id=target_id for update;
  if not found then raise exception 'Actual cost not found'; end if;
  if saved.status <> 'approved' then raise exception 'Only approved cost may be reversed'; end if;
  perform private.actual_cost_assert_mutable(saved.project_id, current_date);

  update public.project_actual_cost_entries
  set status='reversed', reversed_by=actor, reversed_at=now(), reversal_reason=btrim(reason), updated_by=actor, updated_at=now()
  where id=target_id
  returning * into saved;

  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects p
  set actual_cost = coalesce((
        select sum(c.amount)
        from public.project_actual_cost_entries c
        where c.project_id=p.id and c.status='approved'
      ),0),
      updated_by=actor
  where p.id=saved.project_id;

  return to_jsonb(saved);
end $$;

create or replace function public.get_project_cost_variance_snapshot(target_project uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
with project_row as (
  select p.id,
         coalesce(p.expected_cost,0)::numeric expected_cost,
         coalesce(p.actual_cost,0)::numeric actual_cost,
         coalesce(p.revenue,0)::numeric revenue,
         coalesce(p.effective_progress_percentage,p.progress_percentage,0)::numeric progress_percentage
  from public.projects p
  where p.id=target_project and private.project_can_view(p.id)
), approved_budget as (
  select v.id,
         coalesce(v.expected_total_cost,0)::numeric expected_total_cost,
         coalesce(v.target_sale_price,0)::numeric target_sale_price
  from public.project_budget_versions v
  where v.project_id=target_project and v.status='approved'
  order by v.approved_at desc nulls last, v.created_at desc
  limit 1
), category_actual as (
  select cost_category, sum(amount)::numeric total
  from public.project_actual_cost_entries
  where project_id=target_project and status='approved'
  group by cost_category
), normalized_budget_items as (
  select case
    when i.category in ('wood','mdf','plywood','hpl','acrylic','glass','metal','paint','electrical_materials','accessories','consumables','other_materials') then 'material'
    when i.category in ('factory_employees','daily_labor','overtime','technicians','site_labor','temporary_labor') then 'labor'
    when i.category in ('transportation','delivery','loading','unloading','accommodation','travel','permits','site_expenses') then 'transport'
    when i.category in ('rented_equipment') then 'rental'
    when i.category in ('approved_asset_usage_cost','fuel','operation','depreciation_allocation','maintenance_allocation') then 'asset_consumption'
    when i.category in ('subcontractor') then 'subcontract'
    else 'other'
  end cost_category,
  i.total_with_waste::numeric amount
  from public.project_budget_items i
  join approved_budget b on b.id=i.budget_version_id
), category_budget as (
  select cost_category, sum(amount)::numeric total
  from normalized_budget_items
  group by cost_category
), category_keys as (
  select cost_category from category_actual
  union
  select cost_category from category_budget
), category_variance as (
  select k.cost_category,
         coalesce(b.total,0) budget,
         coalesce(a.total,0) actual,
         coalesce(a.total,0)-coalesce(b.total,0) variance,
         case when coalesce(b.total,0)=0 then null
              else round(((coalesce(a.total,0)-b.total)/b.total)*100,2)
         end variance_percentage
  from category_keys k
  left join category_budget b using(cost_category)
  left join category_actual a using(cost_category)
)
select case when private.actual_cost_has_permission('project_actual_cost_view') then
  jsonb_build_object(
    'project_id',p.id,
    'estimated_cost',coalesce(b.expected_total_cost,p.expected_cost),
    'actual_cost',p.actual_cost,
    'remaining_budget',coalesce(b.expected_total_cost,p.expected_cost)-p.actual_cost,
    'variance',p.actual_cost-coalesce(b.expected_total_cost,p.expected_cost),
    'variance_percentage',case when coalesce(b.expected_total_cost,p.expected_cost)=0 then null
      else round(((p.actual_cost-coalesce(b.expected_total_cost,p.expected_cost))/coalesce(b.expected_total_cost,p.expected_cost))*100,2) end,
    'revenue',p.revenue,
    'gross_profit',p.revenue-p.actual_cost,
    'gross_margin_percentage',case when p.revenue=0 then null else round(((p.revenue-p.actual_cost)/p.revenue)*100,2) end,
    'progress_percentage',p.progress_percentage,
    'forecast_final_cost',case when p.progress_percentage > 0 then round(p.actual_cost/(p.progress_percentage/100),2) else p.actual_cost end,
    'forecast_profit',p.revenue-(case when p.progress_percentage > 0 then round(p.actual_cost/(p.progress_percentage/100),2) else p.actual_cost end),
    'categories',coalesce((select jsonb_agg(to_jsonb(category_variance) order by cost_category) from category_variance),'[]'::jsonb)
  ) else null end
from project_row p
left join approved_budget b on true
$$;

revoke all on function public.reject_project_actual_cost(uuid,text) from public,anon;
revoke all on function public.reverse_project_actual_cost(uuid,text) from public,anon;
revoke all on function public.get_project_cost_variance_snapshot(uuid) from public,anon;
grant execute on function public.reject_project_actual_cost(uuid,text) to authenticated;
grant execute on function public.reverse_project_actual_cost(uuid,text) to authenticated;
grant execute on function public.get_project_cost_variance_snapshot(uuid) to authenticated;

commit;
