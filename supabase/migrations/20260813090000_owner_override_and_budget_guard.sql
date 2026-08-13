-- Owner/Super User override policy and approved-budget procurement guard.
-- Business restrictions may be overridden by Owner only with an explicit reason and audit trail.

alter table public.purchase_requests
  add column if not exists budget_override_reason text,
  add column if not exists budget_override_by uuid references public.profiles(id),
  add column if not exists budget_override_at timestamptz;

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
    select v.id
    from public.project_budget_versions v join pr on pr.project_id=v.project_id
    where v.status='approved'
    order by v.version_number desc limit 1
  ), requested as (
    select i.budget_item_id,
           sum(i.quantity) requested_quantity,
           sum(i.quantity*coalesce(i.estimated_unit_cost,0)) requested_amount
    from public.purchase_request_items i
    where i.purchase_request_id=target_request and i.budget_item_id is not null
    group by i.budget_item_id
  ), prior as (
    select i.budget_item_id,
           sum(i.quantity) prior_quantity,
           sum(i.quantity*coalesce(i.estimated_unit_cost,0)) prior_amount
    from public.purchase_request_items i
    join public.purchase_requests r on r.id=i.purchase_request_id
    join pr on r.project_id=pr.project_id
    where r.id<>target_request and r.status in ('submitted','approved','converted') and i.budget_item_id is not null
    group by i.budget_item_id
  ), variance as (
    select bi.id budget_item_id,bi.description,
           bi.quantity budget_quantity,bi.total_with_waste budget_amount,
           coalesce(p.prior_quantity,0) prior_quantity,coalesce(p.prior_amount,0) prior_amount,
           coalesce(q.requested_quantity,0) requested_quantity,coalesce(q.requested_amount,0) requested_amount,
           coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)-bi.quantity quantity_over,
           coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)-bi.total_with_waste amount_over
    from requested q
    join public.project_budget_items bi on bi.id=q.budget_item_id
    join approved_budget ab on ab.id=bi.budget_version_id
    left join prior p on p.budget_item_id=bi.id
    where coalesce(p.prior_quantity,0)+coalesce(q.requested_quantity,0)>bi.quantity
       or coalesce(p.prior_amount,0)+coalesce(q.requested_amount,0)>bi.total_with_waste
  )
  select coalesce(jsonb_agg(to_jsonb(variance)),'[]'::jsonb) from variance
$$;

create or replace function public.decide_purchase_request(target_id uuid, approve boolean, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  role_name text:=public.current_identity_role();
  saved public.purchase_requests%rowtype;
  variances jsonb;
begin
  if role_name not in('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  select * into saved from public.purchase_requests where id=target_id for update;
  if not found or saved.status<>'submitted' then raise exception 'Submitted request required'; end if;

  if approve then
    variances:=private.purchase_request_budget_variances(target_id);
    if jsonb_array_length(variances)>0 then
      if role_name<>'owner' then
        raise exception using errcode='23514',message='Purchase request exceeds the approved project budget; Owner override is required';
      end if;
      if btrim(coalesce(reason,''))='' then
        raise exception using errcode='23514',message='Owner override reason is required for an over-budget purchase request';
      end if;
      update public.purchase_requests
      set status='approved',approved_by=actor,approved_at=now(),rejection_reason=null,
          budget_override_reason=btrim(reason),budget_override_by=actor,budget_override_at=now(),updated_at=now()
      where id=target_id returning * into saved;
      insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
      values('purchase_requests',saved.id::text,'purchase_request_budget_override',actor,to_jsonb(saved),
             jsonb_build_object('reason',btrim(reason),'variances',variances,'policy','owner_break_glass'));
    else
      update public.purchase_requests
      set status='approved',approved_by=actor,approved_at=now(),rejection_reason=null,updated_at=now()
      where id=target_id returning * into saved;
    end if;
  else
    if btrim(coalesce(reason,''))='' then raise exception 'Rejection reason required'; end if;
    update public.purchase_requests set status='rejected',rejected_by=actor,rejected_at=now(),rejection_reason=reason,updated_at=now()
    where id=target_id returning * into saved;
  end if;
  return to_jsonb(saved)||jsonb_build_object('budget_variances',coalesce(variances,'[]'::jsonb));
end
$$;

create or replace function public.owner_override_purchase_request_budget(target_id uuid, override_reason text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
begin
  if public.current_identity_role()<>'owner' then raise exception using errcode='42501',message='Owner role required'; end if;
  if btrim(coalesce(override_reason,''))='' then raise exception using errcode='23514',message='Owner override reason is required'; end if;
  return public.decide_purchase_request(target_id,true,btrim(override_reason));
end
$$;

grant execute on function public.owner_override_purchase_request_budget(uuid,text) to authenticated;

-- Repair budget rejection so rejection is a normal workflow transition and is fully audited.
create or replace function public.reject_project_budget(target_version uuid, rejection_reason text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare actor uuid:=auth.uid(); v public.project_budget_versions%rowtype;
begin
  select * into v from public.project_budget_versions where id=target_version for update;
  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_reject') then raise exception using errcode='42501',message='project_budget_reject permission required'; end if;
  if v.status<>'submitted' then raise exception 'Only a submitted budget may be rejected'; end if;
  if btrim(coalesce(rejection_reason,''))='' then raise exception 'A rejection reason is required'; end if;
  perform set_config('app.project_budget_rpc','on',true);
  update public.project_budget_versions
  set status='rejected',rejection_reason=btrim(rejection_reason),rejected_by=actor,rejected_at=now(),updated_by=actor
  where id=target_version returning * into v;
  perform private.project_budget_activity(v.project_id,'budget_rejected','تم رفض الميزانية التقديرية',jsonb_build_object('budget_version_id',v.id,'version_number',v.version_number,'reason',btrim(rejection_reason)));
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('project_budget_versions',v.id::text,'budget_rejected',actor,to_jsonb(v),jsonb_build_object('reason',btrim(rejection_reason)));
  return to_jsonb(v);
end
$$;
