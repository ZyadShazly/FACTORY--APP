-- Pilot blocker: project purchase requests must not bypass approved budget items.
-- Unlinked or stale/foreign budget-item links are treated as budget variances so
-- only the Owner break-glass path can approve them with an explicit reason.

create or replace function private.purchase_request_budget_variances(target_request uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
with pr as (
  select r.id,r.project_id
  from public.purchase_requests r
  where r.id=target_request
), approved_budget as (
  select v.id,v.expected_total_cost
  from public.project_budget_versions v
  join pr on pr.project_id=v.project_id
  where v.status='approved'
  order by v.version_number desc
  limit 1
), request_lines as (
  select i.*
  from public.purchase_request_items i
  where i.purchase_request_id=target_request
), linked_requested as (
  select i.budget_item_id,
         sum(i.quantity) requested_quantity,
         sum(i.quantity*coalesce(i.estimated_unit_cost,0)) requested_amount
  from request_lines i
  where i.budget_item_id is not null
  group by i.budget_item_id
), linked_prior as (
  select i.budget_item_id,
         sum(i.quantity) prior_quantity,
         sum(i.quantity*coalesce(i.estimated_unit_cost,0)) prior_amount
  from public.purchase_request_items i
  join public.purchase_requests r on r.id=i.purchase_request_id
  join pr on r.project_id=pr.project_id
  where r.id<>target_request
    and r.status in ('submitted','approved','converted')
    and i.budget_item_id is not null
  group by i.budget_item_id
), linked_variance as (
  select 'budget_item'::text variance_type,
         bi.id budget_item_id,
         bi.description,
         bi.quantity budget_quantity,
         bi.total_with_waste budget_amount,
         coalesce(p.prior_quantity,0) prior_quantity,
         coalesce(p.prior_amount,0) prior_amount,
         coalesce(q.requested_quantity,0) requested_quantity,
         coalesce(q.requested_amount,0) requested_amount,
         greatest(coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)-bi.quantity,0) quantity_over,
         greatest(coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)-bi.total_with_waste,0) amount_over
  from linked_requested q
  join public.project_budget_items bi on bi.id=q.budget_item_id
  join approved_budget ab on ab.id=bi.budget_version_id
  left join linked_prior p on p.budget_item_id=bi.id
  where coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)>bi.quantity
     or coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)>bi.total_with_waste
), unlinked_variance as (
  select 'unlinked_budget_item'::text variance_type,
         null::uuid budget_item_id,
         coalesce(i.description,'بند طلب شراء غير مربوط بالميزانية')::text description,
         null::numeric budget_quantity,
         null::numeric budget_amount,
         null::numeric prior_quantity,
         null::numeric prior_amount,
         i.quantity requested_quantity,
         i.quantity*coalesce(i.estimated_unit_cost,0) requested_amount,
         0::numeric quantity_over,
         i.quantity*coalesce(i.estimated_unit_cost,0) amount_over
  from request_lines i
  join pr on true
  where pr.project_id is not null
    and i.budget_item_id is null
), invalid_link_variance as (
  select 'invalid_budget_link'::text variance_type,
         i.budget_item_id,
         coalesce(i.description,'بند طلب شراء مربوط بميزانية غير معتمدة')::text description,
         null::numeric budget_quantity,
         null::numeric budget_amount,
         null::numeric prior_quantity,
         null::numeric prior_amount,
         i.quantity requested_quantity,
         i.quantity*coalesce(i.estimated_unit_cost,0) requested_amount,
         0::numeric quantity_over,
         i.quantity*coalesce(i.estimated_unit_cost,0) amount_over
  from request_lines i
  join pr on true
  left join public.project_budget_items bi on bi.id=i.budget_item_id
  left join approved_budget ab on ab.id=bi.budget_version_id
  where pr.project_id is not null
    and i.budget_item_id is not null
    and ab.id is null
), project_totals as (
  select
    coalesce((select sum(i.quantity*coalesce(i.estimated_unit_cost,0))
      from public.purchase_request_items i
      join public.purchase_requests r on r.id=i.purchase_request_id
      join pr on r.project_id=pr.project_id
      where r.id<>target_request and r.status in ('submitted','approved','converted')),0) prior_amount,
    coalesce((select sum(i.quantity*coalesce(i.estimated_unit_cost,0))
      from request_lines i),0) requested_amount
), project_variance as (
  select 'project_total'::text variance_type,
         null::uuid budget_item_id,
         'إجمالي الميزانية المعتمدة للمشروع'::text description,
         null::numeric budget_quantity,
         ab.expected_total_cost budget_amount,
         null::numeric prior_quantity,
         pt.prior_amount,
         null::numeric requested_quantity,
         pt.requested_amount,
         0::numeric quantity_over,
         greatest(pt.prior_amount+pt.requested_amount-ab.expected_total_cost,0) amount_over
  from approved_budget ab
  cross join project_totals pt
  where pt.prior_amount+pt.requested_amount>ab.expected_total_cost
), all_variances as (
  select * from linked_variance
  union all select * from unlinked_variance
  union all select * from invalid_link_variance
  union all select * from project_variance
)
select coalesce(jsonb_agg(to_jsonb(v)),'[]'::jsonb)
from all_variances v
$$;

-- Minimal, non-financial lookup used by the purchase-request form.
create or replace function public.get_procurement_budget_items(target_project uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then
    raise exception using errcode='42501',message='Procurement access required';
  end if;
  if target_project is null then return '[]'::jsonb; end if;
  if not private.project_can_view(target_project) then
    raise exception using errcode='42501',message='Project access denied';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',bi.id,
      'description',bi.description,
      'category',bi.category,
      'unit',bi.unit,
      'sequence',bi.sequence
    ) order by bi.sequence,bi.created_at)
    from public.project_budget_items bi
    join public.project_budget_versions bv on bv.id=bi.budget_version_id
    where bv.project_id=target_project
      and bv.status='approved'
      and bv.id=(
        select x.id
        from public.project_budget_versions x
        where x.project_id=target_project and x.status='approved'
        order by x.version_number desc
        limit 1
      )
  ),'[]'::jsonb);
end
$$;

revoke all on function public.get_procurement_budget_items(uuid) from public,anon;
grant execute on function public.get_procurement_budget_items(uuid) to authenticated;
