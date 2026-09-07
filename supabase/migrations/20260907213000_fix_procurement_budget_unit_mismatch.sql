-- Prevent false purchase-request budget overruns when the request line unit
-- and the approved budget line unit are not comparable.
--
-- Amount control always applies. Quantity control applies only when all
-- requested/prior quantities for the budget item use the same unit as the
-- approved budget item. This preserves the existing budget guard while
-- avoiding comparisons such as 10 لوح > 1 مجموعة.

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
    select v.id
    from public.project_budget_versions v
    join pr on pr.project_id=v.project_id
    where v.status='approved'
    order by v.version_number desc
    limit 1
  ), requested as (
    select i.budget_item_id,
           sum(i.quantity) requested_quantity,
           sum(i.quantity*coalesce(i.estimated_unit_cost,0)) requested_amount,
           count(distinct nullif(btrim(coalesce(i.unit,'')),'')) requested_unit_count,
           min(nullif(btrim(coalesce(i.unit,'')),'')) requested_unit
    from public.purchase_request_items i
    where i.purchase_request_id=target_request
      and i.budget_item_id is not null
    group by i.budget_item_id
  ), prior as (
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
  ), variance as (
    select bi.id budget_item_id,
           bi.description,
           bi.quantity budget_quantity,
           bi.unit budget_unit,
           bi.total_with_waste budget_amount,
           coalesce(p.prior_quantity,0) prior_quantity,
           coalesce(p.prior_amount,0) prior_amount,
           coalesce(q.requested_quantity,0) requested_quantity,
           coalesce(q.requested_amount,0) requested_amount,
           coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)-bi.quantity quantity_over,
           coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)-bi.total_with_waste amount_over,
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
    from requested q
    join public.project_budget_items bi on bi.id=q.budget_item_id
    join approved_budget ab on ab.id=bi.budget_version_id
    left join prior p on p.budget_item_id=bi.id
    where
      coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)>bi.total_with_waste
      or (
        coalesce(q.requested_unit_count,0)=1
        and coalesce(nullif(btrim(coalesce(bi.unit,'')),''),'')=coalesce(q.requested_unit,'')
        and (
          coalesce(p.prior_quantity,0)=0
          or (
            coalesce(p.prior_unit_count,0)=1
            and coalesce(p.prior_unit,'')=coalesce(q.requested_unit,'')
          )
        )
        and coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)>bi.quantity
      )
  )
  select coalesce(jsonb_agg(to_jsonb(variance)),'[]'::jsonb)
  from variance
$$;

comment on function private.purchase_request_budget_variances(uuid) is
'Checks purchase requests against the latest approved project budget. Amount is always controlled; quantity is controlled only when request/prior units match the budget-item unit.';
