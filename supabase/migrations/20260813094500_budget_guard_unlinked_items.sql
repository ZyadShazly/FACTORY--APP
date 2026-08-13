-- Extend the budget guard to cover project PR lines that are not explicitly linked to a budget item.
-- Linked lines are checked item-by-item; all project requests are also checked against the approved budget total.
-- For single-item approved budgets, quantity is checked even when the UI line was not linked explicitly.

create or replace function private.purchase_request_budget_variances(target_request uuid)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
with pr as (
  select r.id,r.project_id from public.purchase_requests r where r.id=target_request
), approved_budget as (
  select v.id,v.expected_total_cost
  from public.project_budget_versions v join pr on pr.project_id=v.project_id
  where v.status='approved'
  order by v.version_number desc limit 1
), linked_requested as (
  select i.budget_item_id,
         sum(i.quantity) requested_quantity,
         sum(i.quantity*coalesce(i.estimated_unit_cost,0)) requested_amount
  from public.purchase_request_items i
  where i.purchase_request_id=target_request and i.budget_item_id is not null
  group by i.budget_item_id
), linked_prior as (
  select i.budget_item_id,
         sum(i.quantity) prior_quantity,
         sum(i.quantity*coalesce(i.estimated_unit_cost,0)) prior_amount
  from public.purchase_request_items i
  join public.purchase_requests r on r.id=i.purchase_request_id
  join pr on r.project_id=pr.project_id
  where r.id<>target_request and r.status in ('submitted','approved','converted') and i.budget_item_id is not null
  group by i.budget_item_id
), linked_variance as (
  select 'budget_item'::text variance_type, bi.id budget_item_id,bi.description,
         bi.quantity budget_quantity,bi.total_with_waste budget_amount,
         coalesce(p.prior_quantity,0) prior_quantity,coalesce(p.prior_amount,0) prior_amount,
         coalesce(q.requested_quantity,0) requested_quantity,coalesce(q.requested_amount,0) requested_amount,
         greatest(coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)-bi.quantity,0) quantity_over,
         greatest(coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)-bi.total_with_waste,0) amount_over
  from linked_requested q
  join public.project_budget_items bi on bi.id=q.budget_item_id
  join approved_budget ab on ab.id=bi.budget_version_id
  left join linked_prior p on p.budget_item_id=bi.id
  where coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)>bi.quantity
     or coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)>bi.total_with_waste
), project_totals as (
  select
    coalesce((select sum(i.quantity*coalesce(i.estimated_unit_cost,0))
      from public.purchase_request_items i
      join public.purchase_requests r on r.id=i.purchase_request_id
      join pr on r.project_id=pr.project_id
      where r.id<>target_request and r.status in ('submitted','approved','converted')),0) prior_amount,
    coalesce((select sum(i.quantity*coalesce(i.estimated_unit_cost,0))
      from public.purchase_request_items i where i.purchase_request_id=target_request),0) requested_amount
), project_variance as (
  select 'project_total'::text variance_type,null::uuid budget_item_id,'إجمالي الميزانية المعتمدة للمشروع'::text description,
         null::numeric budget_quantity,ab.expected_total_cost budget_amount,
         null::numeric prior_quantity,pt.prior_amount,
         null::numeric requested_quantity,pt.requested_amount,
         0::numeric quantity_over,
         greatest(pt.prior_amount+pt.requested_amount-ab.expected_total_cost,0) amount_over
  from approved_budget ab cross join project_totals pt
  where pt.prior_amount+pt.requested_amount>ab.expected_total_cost
), single_budget as (
  select bi.id,bi.description,bi.quantity,bi.total_with_waste
  from public.project_budget_items bi join approved_budget ab on ab.id=bi.budget_version_id
  where (select count(*) from public.project_budget_items bx where bx.budget_version_id=ab.id)=1
), single_current as (
  select sum(i.quantity) requested_quantity,sum(i.quantity*coalesce(i.estimated_unit_cost,0)) requested_amount
  from public.purchase_request_items i where i.purchase_request_id=target_request
  having count(*)=1
), single_prior as (
  select coalesce(sum(i.quantity),0) prior_quantity,
         coalesce(sum(i.quantity*coalesce(i.estimated_unit_cost,0)),0) prior_amount
  from public.purchase_request_items i
  join public.purchase_requests r on r.id=i.purchase_request_id
  join pr on r.project_id=pr.project_id
  where r.id<>target_request and r.status in ('submitted','approved','converted')
), single_quantity_variance as (
  select 'single_budget_quantity'::text variance_type,sb.id budget_item_id,sb.description,
         sb.quantity budget_quantity,sb.total_with_waste budget_amount,
         sp.prior_quantity,sp.prior_amount,sc.requested_quantity,sc.requested_amount,
         greatest(sp.prior_quantity+sc.requested_quantity-sb.quantity,0) quantity_over,
         greatest(sp.prior_amount+sc.requested_amount-sb.total_with_waste,0) amount_over
  from single_budget sb cross join single_current sc cross join single_prior sp
  where sp.prior_quantity+sc.requested_quantity>sb.quantity
), all_variances as (
  select * from linked_variance
  union all select * from project_variance
  union all select * from single_quantity_variance
)
select coalesce(jsonb_agg(to_jsonb(v)),'[]'::jsonb) from all_variances v
$$;
