-- Follow-up to the Pilot budget-link remediation.
-- Preserve the earlier unit-comparability contract: amount control always applies,
-- while quantity is compared only when request/prior units match the budget line unit.
-- Unlinked and stale/foreign budget-item links remain explicit variances.

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
         sum(i.quantity*coalesce(i.estimated_unit_cost,0)) requested_amount,
         count(distinct nullif(btrim(coalesce(i.unit,'')),'')) requested_unit_count,
         min(nullif(btrim(coalesce(i.unit,'')),'')) requested_unit
  from request_lines i
  where i.budget_item_id is not null
  group by i.budget_item_id
), linked_prior as (
  select i.budget_item_id,
         sum(i.quantity) prior_quantity,
         sum(i.quantity*coalesce(i.estimated_unit_cost,0)) prior_amount,
         count(distinct nullif(btrim(coalesce(i.unit,'')),'')) prior_unit_count,
         min(nullif(btrim(coalesce(i.unit,'')),'')) prior_unit
  from public.purchase_request_items i
  join public.purchase_requests r on r.id=i.purchase_request_id
  join pr on r.project_id=pr.project_id
  where r.id<>target_request
    and r.status in ('submitted','approved','converted')
    and i.budget_item_id is not null
  group by i.budget_item_id
), linked_candidates as (
  select bi.id budget_item_id,
         bi.description,
         bi.quantity budget_quantity,
         bi.unit budget_unit,
         bi.total_with_waste budget_amount,
         coalesce(p.prior_quantity,0) prior_quantity,
         coalesce(p.prior_amount,0) prior_amount,
         coalesce(q.requested_quantity,0) requested_quantity,
         coalesce(q.requested_amount,0) requested_amount,
         (
           coalesce(q.requested_unit_count,0)=1
           and coalesce(nullif(btrim(coalesce(bi.unit,'')),''),'')=coalesce(q.requested_unit,'')
           and (
             coalesce(p.prior_quantity,0)=0
             or (
               coalesce(p.prior_unit_count,0)=1
               and coalesce(p.prior_unit,'')=coalesce(q.requested_unit,'')
             )
           )
         ) quantity_is_comparable
  from linked_requested q
  join public.project_budget_items bi on bi.id=q.budget_item_id
  join approved_budget ab on ab.id=bi.budget_version_id
  left join linked_prior p on p.budget_item_id=bi.id
), linked_variance as (
  select 'budget_item'::text variance_type,
         c.budget_item_id,
         c.description,
         c.budget_quantity,
         c.budget_unit,
         c.budget_amount,
         c.prior_quantity,
         c.prior_amount,
         c.requested_quantity,
         c.requested_amount,
         case when c.quantity_is_comparable
           then greatest(c.prior_quantity+c.requested_quantity-c.budget_quantity,0)
           else 0::numeric end quantity_over,
         greatest(c.prior_amount+c.requested_amount-c.budget_amount,0) amount_over,
         c.quantity_is_comparable
  from linked_candidates c
  where c.prior_amount+c.requested_amount>c.budget_amount
     or (c.quantity_is_comparable and c.prior_quantity+c.requested_quantity>c.budget_quantity)
), unlinked_variance as (
  select 'unlinked_budget_item'::text variance_type,
         null::uuid budget_item_id,
         coalesce(i.description,'بند طلب شراء غير مربوط بالميزانية')::text description,
         null::numeric budget_quantity,
         null::text budget_unit,
         null::numeric budget_amount,
         null::numeric prior_quantity,
         null::numeric prior_amount,
         i.quantity requested_quantity,
         i.quantity*coalesce(i.estimated_unit_cost,0) requested_amount,
         0::numeric quantity_over,
         i.quantity*coalesce(i.estimated_unit_cost,0) amount_over,
         false quantity_is_comparable
  from request_lines i
  join pr on true
  where pr.project_id is not null
    and i.budget_item_id is null
), invalid_link_variance as (
  select 'invalid_budget_link'::text variance_type,
         i.budget_item_id,
         coalesce(i.description,'بند طلب شراء مربوط بميزانية غير معتمدة')::text description,
         null::numeric budget_quantity,
         null::text budget_unit,
         null::numeric budget_amount,
         null::numeric prior_quantity,
         null::numeric prior_amount,
         i.quantity requested_quantity,
         i.quantity*coalesce(i.estimated_unit_cost,0) requested_amount,
         0::numeric quantity_over,
         i.quantity*coalesce(i.estimated_unit_cost,0) amount_over,
         false quantity_is_comparable
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
    coalesce((select sum(i.quantity*coalesce(i.estimated_unit_cost,0)) from request_lines i),0) requested_amount
), project_variance as (
  select 'project_total'::text variance_type,
         null::uuid budget_item_id,
         'إجمالي الميزانية المعتمدة للمشروع'::text description,
         null::numeric budget_quantity,
         null::text budget_unit,
         ab.expected_total_cost budget_amount,
         null::numeric prior_quantity,
         pt.prior_amount,
         null::numeric requested_quantity,
         pt.requested_amount,
         0::numeric quantity_over,
         greatest(pt.prior_amount+pt.requested_amount-ab.expected_total_cost,0) amount_over,
         false quantity_is_comparable
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

comment on function private.purchase_request_budget_variances(uuid) is
'Checks PRs against the latest approved project budget. Amount is always controlled; quantity is controlled only for comparable units. Unlinked/stale links remain explicit variances requiring Owner override.';
