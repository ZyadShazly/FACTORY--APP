-- Fix PL/pgSQL record alias collision in asset cancellation/reversal flows.
-- Additive and rollback-safe: replaces function bodies only, preserves data and grants.

create or replace function public.cancel_pending_asset_assignment(target_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  actor uuid:=auth.uid();
  assignment_row public.asset_assignments%rowtype;
  assignment_item_row public.asset_assignment_items%rowtype;
  affected numeric:=0;
begin
  if actor is null or not exists(
    select 1 from public.profiles where id=actor and role='owner' and status='active'
  ) then
    raise exception 'Owner authorization required' using errcode='42501';
  end if;

  if btrim(coalesce(reason,''))='' then
    raise exception 'Emergency reason is required';
  end if;

  select * into assignment_row
  from public.asset_assignments
  where id=target_id
  for update;

  if assignment_row.id is null or assignment_row.status<>'pending_receiver_confirmation' then
    raise exception 'Only a pending assignment can be cancelled';
  end if;

  if exists(
    select 1
    from public.asset_return_events return_event
    where return_event.assignment_id=assignment_row.id
      and return_event.status not in ('cancelled','expired')
  ) or exists(
    select 1
    from public.asset_settlements settlement
    join public.asset_assignment_items settlement_item
      on settlement_item.id=settlement.assignment_item_id
    where settlement_item.assignment_id=assignment_row.id
      and settlement.status<>'rejected'
  ) then
    raise exception 'Later return or settlement activity prevents cancellation';
  end if;

  if not exists(
    select 1
    from public.asset_assignment_items existing_item
    where existing_item.assignment_id=assignment_row.id
      and existing_item.is_active
  ) then
    raise exception 'Pending assignment has no active items to reverse';
  end if;

  for assignment_item_row in
    select *
    from public.asset_assignment_items assignment_item
    where assignment_item.assignment_id=assignment_row.id
      and assignment_item.is_active
    for update
  loop
    if assignment_item_row.returned_quantity<>0 or assignment_item_row.settled_quantity<>0 then
      raise exception 'Assignment quantities are no longer reversible';
    end if;

    insert into public.asset_movements(
      asset_id,movement_type,quantity,available_delta,assigned_delta,
      assignment_id,reason,metadata
    ) values(
      assignment_item_row.asset_id,'reversed',assignment_item_row.quantity,
      assignment_item_row.quantity,-assignment_item_row.quantity,
      assignment_row.id,btrim(reason),
      jsonb_build_object(
        'source','admin_override',
        'override_type','pending_issue_cancelled',
        'actor_id',actor
      )
    );

    update public.asset_assignment_items
    set is_active=false
    where id=assignment_item_row.id;

    affected:=affected+assignment_item_row.quantity;
  end loop;

  update public.asset_assignments
  set status='reversed',
      reversed_at=now(),
      reversal_reason=btrim(reason),
      confirmation_token_hash=null,
      override_type='pending_issue_cancelled',
      override_actor_id=actor,
      override_at=now(),
      override_reason=btrim(reason),
      override_source='admin_override',
      updated_by=actor,
      updated_at=now()
  where id=assignment_row.id;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,old_data,new_data,metadata
  ) values(
    'asset_assignments',assignment_row.id::text,'pending_issue_cancelled',actor,
    to_jsonb(assignment_row),
    (select to_jsonb(current_assignment)
     from public.asset_assignments current_assignment
     where current_assignment.id=assignment_row.id),
    jsonb_build_object(
      'source','admin_override',
      'reason',btrim(reason),
      'affected_quantity',affected
    )
  );

  return jsonb_build_object(
    'ok',true,
    'status','reversed',
    'affected_quantity',affected
  );
end
$$;

create or replace function public.reverse_asset_assignment(target_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  actor uuid:=auth.uid();
  assignment_row public.asset_assignments%rowtype;
  assignment_item_row public.asset_assignment_items%rowtype;
  affected numeric:=0;
begin
  if actor is null or not exists(
    select 1 from public.profiles where id=actor and role='owner' and status='active'
  ) then
    raise exception 'Owner authorization required' using errcode='42501';
  end if;

  if btrim(coalesce(reason,''))='' then
    raise exception 'Emergency reason is required';
  end if;

  select * into assignment_row
  from public.asset_assignments
  where id=target_id
  for update;

  if assignment_row.id is null or assignment_row.status<>'issued' then
    raise exception 'Only an issued assignment can be reversed';
  end if;

  if exists(
    select 1
    from public.asset_assignment_items existing_item
    where existing_item.assignment_id=assignment_row.id
      and (existing_item.returned_quantity<>0 or existing_item.settled_quantity<>0)
  ) or exists(
    select 1
    from public.asset_return_events return_event
    where return_event.assignment_id=assignment_row.id
      and return_event.status not in ('cancelled','expired')
  ) or exists(
    select 1
    from public.asset_settlements settlement
    join public.asset_assignment_items settlement_item
      on settlement_item.id=settlement.assignment_item_id
    where settlement_item.assignment_id=assignment_row.id
      and settlement.status<>'rejected'
  ) then
    raise exception 'Later returns or settlements make reversal inconsistent';
  end if;

  if not exists(
    select 1
    from public.asset_assignment_items existing_item
    where existing_item.assignment_id=assignment_row.id
      and existing_item.is_active
  ) then
    raise exception 'Issued assignment has no active items to reverse';
  end if;

  for assignment_item_row in
    select *
    from public.asset_assignment_items assignment_item
    where assignment_item.assignment_id=assignment_row.id
      and assignment_item.is_active
    for update
  loop
    insert into public.asset_movements(
      asset_id,movement_type,quantity,available_delta,assigned_delta,
      assignment_id,reason,metadata
    ) values(
      assignment_item_row.asset_id,'reversed',assignment_item_row.quantity,
      assignment_item_row.quantity,-assignment_item_row.quantity,
      assignment_row.id,btrim(reason),
      jsonb_build_object(
        'source','admin_override',
        'override_type','issued_assignment_reversal',
        'actor_id',actor
      )
    );

    update public.asset_assignment_items
    set is_active=false
    where id=assignment_item_row.id;

    affected:=affected+assignment_item_row.quantity;
  end loop;

  update public.asset_assignments
  set status='reversed',
      reversed_at=now(),
      reversal_reason=btrim(reason),
      override_type='issued_assignment_reversal',
      override_actor_id=actor,
      override_at=now(),
      override_reason=btrim(reason),
      override_source='admin_override',
      updated_by=actor,
      updated_at=now()
  where id=assignment_row.id;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,old_data,new_data,metadata
  ) values(
    'asset_assignments',assignment_row.id::text,'issued_assignment_reversal',actor,
    to_jsonb(assignment_row),
    (select to_jsonb(current_assignment)
     from public.asset_assignments current_assignment
     where current_assignment.id=assignment_row.id),
    jsonb_build_object(
      'source','admin_override',
      'reason',btrim(reason),
      'affected_quantity',affected
    )
  );

  return jsonb_build_object(
    'ok',true,
    'status','reversed',
    'affected_quantity',affected
  );
end
$$;
