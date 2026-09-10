-- Closed project revenue is a customer charge. Allow customer advances received
-- before closure to be allocated to that project so due and advance balances reconcile.

alter table public.customer_advance_allocations
  drop constraint if exists customer_advance_allocations_target_type_check;
alter table public.customer_advance_allocations
  add constraint customer_advance_allocations_target_type_check
  check (target_type in ('sale','rental','project'));

create or replace function private.customer_advance_target_remaining(
  target_type text,
  target_id uuid,
  target_customer uuid
)
returns numeric
language sql
stable
security invoker
set search_path=''
as $$
  select greatest(0, coalesce(case
    when target_type='sale' then (
      select s.total from public.sales s
      where s.id=target_id and s.customer_id=target_customer and s.status='posted'
    )
    when target_type='rental' then (
      select r.rental_fee from public.rentals r
      where r.id=target_id and r.customer_id=target_customer and r.status<>'cancelled'
    )
    when target_type='project' then (
      select p.revenue from public.projects p
      where p.id=target_id and p.customer_id=target_customer
        and p.lifecycle='closed' and coalesce(p.revenue,0)>0
    )
  end,0) - coalesce((
    select sum(a.amount) from public.customer_advance_allocations a
    where a.target_type=customer_advance_target_remaining.target_type
      and a.target_id=customer_advance_target_remaining.target_id
      and a.status='allocated'
  ),0))
$$;

revoke all on function private.customer_advance_target_remaining(text,uuid,uuid)
  from public,anon,authenticated;

-- Keep the existing workspace implementation as a private core and expose a
-- compatible wrapper that adds closed projects as customer allocation targets.
alter function public.get_commercial_advance_workspace(text,uuid)
  rename to get_commercial_advance_workspace_core;
revoke all on function public.get_commercial_advance_workspace_core(text,uuid)
  from public,anon,authenticated;

create or replace function public.get_commercial_advance_workspace(
  party_type text,
  target_party uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  result jsonb;
  project_targets jsonb:='[]'::jsonb;
  normalized_allocations jsonb:='[]'::jsonb;
begin
  result:=public.get_commercial_advance_workspace_core(party_type,target_party);
  if party_type<>'customer' then return result; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'type','project',
    'id',p.id,
    'date',coalesce(p.project_closed_at,p.lifecycle_changed_at,p.delivery_date::timestamptz,p.updated_at)::date,
    'label','مشروع · '||coalesce(p.project_code||' · ','')||coalesce(p.project_name,'مشروع'),
    'document_amount',p.revenue,
    'remaining_amount',private.customer_advance_target_remaining('project',p.id,target_party)
  ) order by coalesce(p.project_closed_at,p.lifecycle_changed_at,p.updated_at),p.project_code),'[]'::jsonb)
  into project_targets
  from public.projects p
  where p.customer_id=target_party
    and p.lifecycle='closed'
    and coalesce(p.revenue,0)>0
    and private.customer_advance_target_remaining('project',p.id,target_party)>0;

  result:=jsonb_set(
    result,
    '{targets}',
    coalesce(result->'targets','[]'::jsonb)||project_targets,
    true
  );

  select coalesce(jsonb_agg(
    case when allocation->>'target_type'='project'
      then jsonb_set(allocation,'{target_label}',to_jsonb('مشروع'::text),true)
      else allocation end
  ),'[]'::jsonb)
  into normalized_allocations
  from jsonb_array_elements(coalesce(result->'allocations','[]'::jsonb)) allocation;

  result:=jsonb_set(result,'{allocations}',normalized_allocations,true);
  return result;
end
$$;

revoke all on function public.get_commercial_advance_workspace(text,uuid)
  from public,anon;
grant execute on function public.get_commercial_advance_workspace(text,uuid)
  to authenticated;

create or replace function public.allocate_customer_advance(
  source_receipt uuid,
  target_type text,
  target_id uuid,
  allocation_amount numeric,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  source public.customer_receipts%rowtype;
  saved public.customer_advance_allocations%rowtype;
  target_remaining numeric;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;

  select * into saved
  from public.customer_advance_allocations
  where customer_advance_allocations.command_id=allocate_customer_advance.command_id;
  if found then return to_jsonb(saved); end if;

  select * into source
  from public.customer_receipts
  where id=source_receipt
  for update;
  if not found or source.status<>'posted'
     or source.transaction_classification not in ('advance','mixed') then
    raise exception 'Posted customer advance required';
  end if;

  if target_type='sale' then
    perform 1 from public.sales
    where id=target_id and customer_id=source.customer_id and status='posted'
    for update;
  elsif target_type='rental' then
    perform 1 from public.rentals
    where id=target_id and customer_id=source.customer_id and status<>'cancelled'
    for update;
  elsif target_type='project' then
    perform 1 from public.projects
    where id=target_id and customer_id=source.customer_id
      and lifecycle='closed' and coalesce(revenue,0)>0
    for update;
  else
    raise exception 'Valid customer document required';
  end if;
  if not found then raise exception 'Valid customer document required'; end if;

  target_remaining:=private.customer_advance_target_remaining(
    target_type,target_id,source.customer_id
  );
  if allocation_amount is null or allocation_amount<=0
     or allocation_amount>source.advance_amount-source.allocated_advance_amount then
    raise exception 'Allocation exceeds available customer advance';
  end if;
  if allocation_amount>private.customer_due(source.customer_id) then
    raise exception 'Allocation exceeds customer due';
  end if;
  if allocation_amount>target_remaining then
    raise exception 'Allocation exceeds customer document balance';
  end if;

  insert into public.customer_advance_allocations(
    receipt_id,customer_id,target_type,target_id,amount,command_id
  ) values(
    source.id,source.customer_id,target_type,target_id,allocation_amount,command_id
  ) returning * into saved;

  perform set_config('app.commercial_advance_rpc','on',true);
  update public.customer_receipts
  set allocated_advance_amount=allocated_advance_amount+allocation_amount
  where id=source.id;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'customer_advance_allocations',saved.id::text,'customer_advance_allocated',
    auth.uid(),to_jsonb(saved),
    jsonb_build_object(
      'receipt_id',source.id,
      'target_type',target_type,
      'target_id',target_id,
      'target_remaining_before',target_remaining
    )
  );
  return to_jsonb(saved);
end
$$;

revoke all on function public.allocate_customer_advance(uuid,text,uuid,numeric,uuid)
  from public,anon;
grant execute on function public.allocate_customer_advance(uuid,text,uuid,numeric,uuid)
  to authenticated;
